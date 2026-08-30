package PJJ::Auth;
# サインアップ／サインインのエンドポイントそのもの。
#
#   POST   ?action=signup_request  {email}                 確認リンクをメールで送る（まだ作らない）
#   GET    ?action=signup_verify&token=<t>                 リンクの有効性を確かめ email を返す
#   POST   ?action=signup_complete {token,username,password} 登録してログイン状態に
#   POST   ?action=login           {email,password}        ログイン
#   POST   ?action=logout                                  ログアウト
#   GET    ?action=me                                      ログイン中のアカウント（未ログインは 401）
#   POST   ?action=change_password {current_password,new_password}
#   POST   ?action=reset_request   {email}                 再設定リンクをメールで送る
#   GET    ?action=reset_verify&token=<t>                  リンクの有効性を確かめ email を返す
#   POST   ?action=reset_complete  {token,password}        新パスワードを設定してログイン状態に
#   DELETE ?action=account                                 退会（関連データは ON DELETE CASCADE）
#
# 使い方: api.cgi のルーティングの先頭で1度呼ぶ。担当する action なら応答して exit するので、
# 戻ってきたときはアプリ固有のルーティングへ進んでよい。
#
#   auth_dispatch($dbh, $action, $method);
#
# アプリごとの違い（ボディ形式・メール内リンクの書式・アカウント応答の形・レート制限の有無・
# ゲスト昇格・再設定の対象）は、すべて PJJ->init の引数で渡す。
#
# メールアドレスの存在は常に秘匿する（登録済みでも未登録でも同じ応答を返し、登録済みには
# リンクの代わりに「既にアカウントがあります」の案内を送る）。ログインは、ユーザーが
# 居なくてもダミーで PBKDF2 を回して応答時間からの列挙も防ぐ。

use strict;
use warnings;
use JSON::PP ();
use Exporter ();
use PJJ ();
use PJJ::Web       qw(respond fail query_param read_body_json body_param get_cookie app_base_url);
use PJJ::Crypt     qw(random_hex pbkdf2 const_eq);
use PJJ::DB        qw(pgbool);
use PJJ::Session   qw(start_session current_user require_user clear_session_cookie
                      purge_expired_signup_tokens purge_expired_reset_tokens);
use PJJ::Mail      qw(send_signup_email send_reset_email send_signup_exists_email);
use PJJ::RateLimit qw(rate_count rate_add rate_clear purge_old_rate_events);

our @ISA    = ('Exporter');
our @EXPORT = qw(auth_dispatch);

my %HANDLER = (
    'signup_request:POST'  => \&_signup_request,
    'signup_verify:GET'    => \&_signup_verify,
    'signup_complete:POST' => \&_signup_complete,
    'login:POST'           => \&_login,
    'logout:POST'          => \&_logout,
    'me:GET'               => \&_me,
    'change_password:POST' => \&_change_password,
    'reset_request:POST'   => \&_reset_request,
    'reset_verify:GET'     => \&_reset_verify,
    'reset_complete:POST'  => \&_reset_complete,
    'account:DELETE'       => \&_delete_account,
);

# 担当する action なら処理して exit する。担当外なら 0 を返す。
sub auth_dispatch {
    my ($dbh, $action, $method) = @_;
    my $only = PJJ::conf('auth_actions');
    return 0 if $only && !grep { $_ eq $action } @$only;
    my $h = $HANDLER{"$action:$method"} or return 0;
    $h->($dbh);
    return 1;   # ハンドラは respond して exit するので、ここには来ない
}

# ---- 入力 ------------------------------------------------------------------
# ボディの値を1つ取り出す。JSON でもフォームでも同じ呼び方にする。
my $BODY;
sub _param {
    my ($name) = @_;
    return body_param($name) if PJJ::conf('body_format') eq 'form';
    $BODY = read_body_json() unless defined $BODY;
    return $BODY->{$name};
}
sub _str { my $v = _param($_[0]); return defined $v ? $v : '' }
sub _trimmed { my $v = _str($_[0]); $v =~ s/^\s+|\s+$//g; return $v }

sub _check_password {
    my ($p) = @_;
    fail('password_too_short') if length($p) < PJJ::conf('password_min');
    fail('password_too_long')  if length($p) > PJJ::conf('password_max');
}

# ---- 設定の取り出し --------------------------------------------------------
# アカウント応答。既定は {username, email}。is_admin / guest などはアプリ側で足す。
sub _account_json {
    my ($u) = @_;
    my $f = PJJ::conf('account_json');
    return $f->($u) if $f;
    return { username => $u->{username}, email => $u->{email} };
}

# メール内リンク。既定は "<ベースURL>?signup=<token>" 形式。
sub _signup_link { my $f = PJJ::conf('signup_link'); $f ? $f->($_[0]) : app_base_url() . "?signup=$_[0]" }
sub _reset_link  { my $f = PJJ::conf('reset_link');  $f ? $f->($_[0]) : app_base_url() . "?reset=$_[0]"  }
sub _login_link  { my $f = PJJ::conf('login_link');  $f ? $f->()      : app_base_url() }

# users から引く列。アプリ固有の列（is_guest / is_admin）は user_columns で足す。
sub _user_cols {
    my ($prefix, @base) = @_;
    my @cols = (@base, @{ PJJ::conf('user_columns') || [] });
    return join(', ', map { "$prefix$_" } @cols);
}

# ---- レート制限（設定が無ければ何もしない） --------------------------------
sub _rl { PJJ::conf('rate_limit') }
sub _ip { defined $ENV{REMOTE_ADDR} ? $ENV{REMOTE_ADDR} : '' }

# 直近の件数がしきい値に達しているか（メール宛先・IP のどちらかで超えたら真）。
sub _over_limit {
    my ($dbh, $rl, $action, $email, $win, $max_email, $max_ip) = @_;
    my $ip = _ip();
    return 1 if rate_count($dbh, $action, 'email:' . lc($email), $rl->{$win}) >= $rl->{$max_email};
    return 1 if $ip ne '' && rate_count($dbh, $action, 'ip:' . $ip, $rl->{$win}) >= $rl->{$max_ip};
    return 0;
}

sub _rate_record {
    my ($dbh, $action, $email) = @_;
    my $ip = _ip();
    rate_add($dbh, $action, 'email:' . lc($email));
    rate_add($dbh, $action, 'ip:' . $ip) if $ip ne '';
}

# ---- サインアップ ----------------------------------------------------------
sub _signup_request {
    my ($dbh) = @_;
    my $email = _trimmed('email');
    fail('email_required') if $email eq '';
    fail('email_invalid')  if length($email) > 254 || $email !~ /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

    # メール爆撃対策: 直近の送信が宛先/IP ごとに多すぎるときは送らない。存在秘匿・スロットル
    # 秘匿のため応答は常に {ok}。しきい値内なら1通ぶんを記録してから送る。
    if (my $rl = _rl()) {
        respond({ ok => JSON::PP::true })
            if _over_limit($dbh, $rl, 'mail_signup', $email,
                           'mail_window_min', 'mail_max_per_email', 'mail_max_per_ip');
        _rate_record($dbh, 'mail_signup', $email);
        purge_old_rate_events($dbh);
    }

    # 既に登録済みのメールでも、存在の有無を秘匿するため未登録時と同じ {ok} を返す
    # （メールアドレスの探り出しを防ぐ）。その場合は登録リンクではなく「既にアカウントが
    # あります」の案内メールを送る（リンクを送っても signup_complete で弾かれるだけ）。
    if ($dbh->selectrow_array('SELECT 1 FROM users WHERE lower(email) = lower(?)', undef, $email)) {
        send_signup_exists_email($email, _login_link());
        respond({ ok => JSON::PP::true });
    }

    # 同じメール宛の古いトークンは破棄し、新しいトークンを発行する。
    $dbh->do('DELETE FROM signup_tokens WHERE lower(email) = lower(?)', undef, $email);
    my $token = random_hex(32);
    my $hours = PJJ::conf('signup_token_hours');
    $dbh->do(
        "INSERT INTO signup_tokens (token, email, expires_at)
         VALUES (?,?, now() + interval '$hours hours')",
        undef, $token, $email
    );
    purge_expired_signup_tokens($dbh);
    send_signup_email($email, _signup_link($token))
        or fail('mail_failed', '500 Internal Server Error');
    respond({ ok => JSON::PP::true });
}

sub _signup_verify {
    my ($dbh) = @_;
    my $token = query_param('token') || '';
    my $email = $dbh->selectrow_array(
        'SELECT email FROM signup_tokens WHERE token = ? AND expires_at > now()', undef, $token);
    fail('signup_token_invalid', '400 Bad Request') unless defined $email;
    respond({ email => $email });
}

# 既定のユーザー作成。ゲスト昇格のように別扱いが要るアプリは signup_create_user で差し替える。
sub _create_user {
    my ($dbh, $a) = @_;
    return $dbh->selectrow_array(
        'INSERT INTO users (username, email, password_hash, salt, iterations)
         VALUES (?,?,?,?,?) RETURNING id',
        undef, $a->{username}, $a->{email}, $a->{hash}, $a->{salt}, $a->{iterations}
    );
}

sub _signup_complete {
    my ($dbh) = @_;
    my $token    = _str('token');
    my $password = _str('password');
    my $username = _trimmed('username');

    my $email = $dbh->selectrow_array(
        'SELECT email FROM signup_tokens WHERE token = ? AND expires_at > now()', undef, $token);
    fail('signup_token_invalid', '400 Bad Request') unless defined $email;

    fail('username_length') if $username eq '' || length($username) > PJJ::conf('username_max');
    _check_password($password);

    # 申請〜確定の間に同じメール/ユーザー名が使われていないか再確認する。
    my @taken;
    push @taken, 'email'
        if $dbh->selectrow_array('SELECT 1 FROM users WHERE lower(email) = lower(?)', undef, $email);
    push @taken, 'username'
        if $dbh->selectrow_array('SELECT 1 FROM users WHERE username = ?', undef, $username);
    respond({ error => 'duplicate', fields => \@taken }, '409 Conflict') if @taken;

    my $iter = PJJ::conf('pbkdf2_iter');
    my $salt = random_hex(16);
    my $hash = pbkdf2($password, $salt, $iter);
    my $create = PJJ::conf('signup_create_user') || \&_create_user;
    my $uid = $create->($dbh, {
        username => $username, email => $email,
        hash => $hash, salt => $salt, iterations => $iter,
    });

    # 使い終わったトークン（同じメール宛のものも含めて）を削除する。
    $dbh->do('DELETE FROM signup_tokens WHERE lower(email) = lower(?)', undef, $email);
    start_session($dbh, $uid);
    respond(_account_json({ username => $username, email => $email }));
}

# ---- ログイン --------------------------------------------------------------
sub _login {
    my ($dbh) = @_;
    my $email    = _trimmed('email');
    my $password = _str('password');
    my $iter     = PJJ::conf('pbkdf2_iter');
    my $rl       = _rl();
    my $ekey     = 'email:' . lc($email);

    # 直近の失敗が多すぎる（同一メール or 同一IP）なら一時的に拒否する（総当たり抑止）。
    if ($rl) {
        fail('too_many_attempts', '429 Too Many Requests')
            if _over_limit($dbh, $rl, 'login_fail', $email,
                           'login_window_min', 'login_max_per_email', 'login_max_per_ip');
    }

    # メールアドレスでログイン（大文字小文字を無視）。
    my $cols = _user_cols('', qw(id username email password_hash salt iterations));
    my $u = $dbh->selectrow_hashref(
        "SELECT $cols FROM users WHERE lower(email) = lower(?)", undef, $email);

    # ユーザーが存在しなくてもダミーで PBKDF2 を回し、応答時間でのアカウント列挙を防ぐ。
    my $ok = 0;
    if ($u) {
        $ok = const_eq(pbkdf2($password, $u->{salt}, $u->{iterations}), $u->{password_hash});
    } else {
        pbkdf2($password, '0' x 32, $iter);
    }
    unless ($ok) {
        if ($rl) {
            _rate_record($dbh, 'login_fail', $email);
            purge_old_rate_events($dbh);
        }
        fail('invalid_credentials', '401 Unauthorized');
    }
    # 成功したらそのメールの失敗記録をクリア（正規利用者が締め出されないように）。
    rate_clear($dbh, 'login_fail', $ekey) if $rl;

    start_session($dbh, $u->{id});
    if (my $after = PJJ::conf('on_login')) { $after->($dbh, $u) }
    respond(_account_json($u));
}

sub _logout {
    my ($dbh) = @_;
    my $token = get_cookie(PJJ::conf('cookie_name'));
    $dbh->do('DELETE FROM sessions WHERE token = ?', undef, $token)
        if defined $token && $token =~ /^[0-9a-f]{16,128}$/;
    clear_session_cookie();
    respond({ ok => JSON::PP::true });
}

sub _me {
    my ($dbh) = @_;
    respond(_account_json(require_user($dbh)));
}

# ---- パスワード ------------------------------------------------------------
sub _change_password {
    my ($dbh) = @_;
    my $u = require_user($dbh);
    my $current = _str('current_password');
    my $new     = _str('new_password');

    # 現在のパスワードを確認（保存済みの salt/iterations で照合）。
    my $row = $dbh->selectrow_hashref(
        'SELECT password_hash, salt, iterations FROM users WHERE id = ?', undef, $u->{id});
    fail('not_found', '404 Not Found') unless $row;
    fail('current_password_wrong', '403 Forbidden')
        unless const_eq(pbkdf2($current, $row->{salt}, $row->{iterations}), $row->{password_hash});

    # 新しいパスワードを検証して、新しい salt で作り直して保存する。
    _check_password($new);
    _store_password($dbh, $u->{id}, $new);
    respond({ ok => JSON::PP::true });
}

sub _store_password {
    my ($dbh, $uid, $password) = @_;
    my $iter = PJJ::conf('pbkdf2_iter');
    my $salt = random_hex(16);
    my $hash = pbkdf2($password, $salt, $iter);
    $dbh->do('UPDATE users SET password_hash = ?, salt = ?, iterations = ? WHERE id = ?',
        undef, $hash, $salt, $iter, $uid);
}

sub _reset_request {
    my ($dbh) = @_;
    my $email = _trimmed('email');
    fail('email_required') if $email eq '';
    my $rl = _rl();

    # メール爆撃対策（応答は常に {ok}）。実際に送るときだけ1通ぶんを記録する
    # （爆撃されるのは実在アドレス宛のため）。
    if ($rl) {
        respond({ ok => JSON::PP::true })
            if _over_limit($dbh, $rl, 'mail_reset', $email,
                           'mail_window_min', 'mail_max_per_email', 'mail_max_per_ip');
    }

    my $cols = _user_cols('', qw(id email));
    my $u = $dbh->selectrow_hashref(
        "SELECT $cols FROM users WHERE lower(email) = lower(?)", undef, $email);
    # 再設定を受け付けないユーザー（一時ユーザーなど）は居なかったことにする。
    my $eligible = PJJ::conf('reset_eligible');
    $u = undef if $u && $eligible && !$eligible->($u);

    if ($u) {
        _rate_record($dbh, 'mail_reset', $email) if $rl;
        # 同じユーザー宛の古いトークンは破棄し、新しいトークンを発行する。
        $dbh->do('DELETE FROM reset_tokens WHERE user_id = ?', undef, $u->{id});
        my $token = random_hex(32);
        my $hours = PJJ::conf('reset_token_hours');
        $dbh->do(
            "INSERT INTO reset_tokens (token, user_id, expires_at)
             VALUES (?,?, now() + interval '$hours hours')",
            undef, $token, $u->{id}
        );
        # 送信に失敗しても存在秘匿のため ok を返す（詳細はサーバーログへ）。
        send_reset_email($u->{email}, _reset_link($token));
    }
    purge_expired_reset_tokens($dbh);
    purge_old_rate_events($dbh) if $rl;
    # 存在の有無は秘匿。登録の有無に関わらず {ok} を返す。
    respond({ ok => JSON::PP::true });
}

sub _reset_verify {
    my ($dbh) = @_;
    my $token = query_param('token') || '';
    my $email = $dbh->selectrow_array(
        'SELECT u.email FROM reset_tokens r JOIN users u ON u.id = r.user_id
          WHERE r.token = ? AND r.expires_at > now()', undef, $token);
    fail('reset_token_invalid', '400 Bad Request') unless defined $email;
    respond({ email => $email });
}

sub _reset_complete {
    my ($dbh) = @_;
    my $token    = _str('token');
    my $password = _str('password');

    my $cols = _user_cols('u.', qw(id username email));
    my $row = $dbh->selectrow_hashref(
        "SELECT $cols FROM reset_tokens r JOIN users u ON u.id = r.user_id
          WHERE r.token = ? AND r.expires_at > now()", undef, $token);
    fail('reset_token_invalid', '400 Bad Request') unless $row;
    _check_password($password);

    _store_password($dbh, $row->{id}, $password);
    # 使い終わったトークンを削除し、既存セッションも全て無効化してから作り直す
    # （盗まれていた可能性のある古いセッションを切るため）。
    $dbh->do('DELETE FROM reset_tokens WHERE user_id = ?', undef, $row->{id});
    $dbh->do('DELETE FROM sessions WHERE user_id = ?', undef, $row->{id});
    start_session($dbh, $row->{id});
    respond(_account_json($row));
}

# ---- 退会 ------------------------------------------------------------------
# users を消すと、そのユーザーに紐づく行は ON DELETE CASCADE で道連れに削除される
# （何が消えるかは各アプリの ddl/ 参照）。
sub _delete_account {
    my ($dbh) = @_;
    my $u = require_user($dbh);
    $dbh->do('DELETE FROM users WHERE id = ?', undef, $u->{id});
    clear_session_cookie();
    respond({ ok => JSON::PP::true });
}

1;
