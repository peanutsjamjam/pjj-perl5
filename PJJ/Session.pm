package PJJ::Session;
# セッション（ログイン状態）の管理。
#
# ログイン時にランダムトークンを sessions に保存し、HttpOnly Cookie で受け渡す。
# 期限切れ行の掃除は「ついで掃除」として各所から呼ぶ（cron を持たずにテーブルの
# 肥大化を防ぐ）。掃除に失敗してもリクエスト自体は止めない（warn のみ）。

use strict;
use warnings;
use Exporter ();
use PJJ ();
use PJJ::Web qw(add_header get_cookie fail);
use PJJ::Crypt qw(random_hex);

our @ISA    = ('Exporter');
our @EXPORT = qw(
    set_session_cookie clear_session_cookie start_session
    current_user require_user
    purge_expired_sessions purge_expired_signup_tokens purge_expired_reset_tokens
);

# ---- Cookie ----------------------------------------------------------------
sub set_session_cookie {
    my ($token, $days) = @_;
    $days ||= PJJ::conf('session_days');
    my $name = PJJ::conf('cookie_name');
    my $path = PJJ::conf('cookie_path');
    my $max  = $days * 24 * 3600;
    add_header("Set-Cookie: $name=$token; Path=$path; Max-Age=$max; HttpOnly; Secure; SameSite=Lax");
}

sub clear_session_cookie {
    my $name = PJJ::conf('cookie_name');
    my $path = PJJ::conf('cookie_path');
    add_header("Set-Cookie: $name=; Path=$path; Max-Age=0; HttpOnly; Secure; SameSite=Lax");
}

# ---- セッションの作成・参照 ------------------------------------------------
# 新しいセッションを作って Cookie を張る。作ったトークンを返す。
sub start_session {
    my ($dbh, $uid, $days) = @_;
    $days ||= PJJ::conf('session_days');
    my $token = random_hex(32);
    $dbh->do(
        "INSERT INTO sessions (token, user_id, expires_at)
         VALUES (?,?, now() + interval '$days days')",
        undef, $token, $uid
    );
    purge_expired_sessions($dbh);
    set_session_cookie($token, $days);
    return $token;
}

# current_user が users から引く列。id / username / email に加えて、アプリ固有の列
# （nenpyo の is_guest、wslfan/zigsaw の is_admin）を PJJ->init(user_columns => [...]) で足す。
sub _user_select_list {
    my @cols = ('id', 'username', 'email');
    my $extra = PJJ::conf('user_columns') || [];
    for my $c (@$extra) {
        die "PJJ::Session: bad user_columns entry '$c'\n" unless $c =~ /^[a-z_][a-z0-9_]*$/;
        push @cols, $c;
    }
    return join(', ', map { "u.$_" } @cols);
}

# 現在のログインユーザーのハッシュリファレンスを返す。未ログインなら undef。
sub current_user {
    my ($dbh) = @_;
    my $token = get_cookie(PJJ::conf('cookie_name'));
    return undef unless defined $token && $token =~ /^[0-9a-f]{16,128}$/;
    my $cols = _user_select_list();
    return $dbh->selectrow_hashref(
        "SELECT $cols FROM sessions s
           JOIN users u ON u.id = s.user_id
          WHERE s.token = ? AND s.expires_at > now()",
        undef, $token
    );
}

sub require_user {
    my ($dbh) = @_;
    my $u = current_user($dbh);
    fail('not_authenticated', '401 Unauthorized') unless $u;
    return $u;
}

# ---- ついで掃除 ------------------------------------------------------------
sub _purge {
    my ($dbh, $what, $sql) = @_;
    eval { $dbh->do($sql); 1 } or warn "purge_$what failed: $@\n";
}

sub purge_expired_sessions {
    _purge($_[0], 'expired_sessions', 'DELETE FROM sessions WHERE expires_at < now()');
}

sub purge_expired_signup_tokens {
    _purge($_[0], 'expired_signup_tokens', 'DELETE FROM signup_tokens WHERE expires_at < now()');
}

sub purge_expired_reset_tokens {
    _purge($_[0], 'expired_reset_tokens', 'DELETE FROM reset_tokens WHERE expires_at < now()');
}

1;
