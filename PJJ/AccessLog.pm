package PJJ::AccessLog;
# アクセスログ。リクエストごとに、送信元 IP と（ログイン中なら）その user_id を1行記録する。
# クライアント IP は Apache が付ける REMOTE_ADDR を使う。
# 記録に失敗してもリクエスト自体は止めない（warn のみ）。$user_id は未ログインなら undef（NULL）。
#
# 必要なテーブル（ddl/access_log.sql）:
#   access_log (id, user_id, ip_addr, accessed_at TIMESTAMPTZ DEFAULT now())

use strict;
use warnings;
use Exporter ();
use PJJ ();

our @ISA    = ('Exporter');
our @EXPORT = qw(log_access purge_old_access_log);

sub log_access {
    my ($dbh, $user_id) = @_;
    my $ip = $ENV{REMOTE_ADDR};
    return unless defined $ip && $ip ne '';
    eval { $dbh->do('INSERT INTO access_log (user_id, ip_addr) VALUES (?, ?)', undef, $user_id, $ip); 1 }
        or warn "log_access failed: $@\n";
    # 毎リクエストで DELETE を打つのは無駄なので、たまに（約2%）だけ古い行を掃除する。
    # 保持日数を設定していないアプリでは掃除しない。
    my $keep = PJJ::conf('access_log_keep_days');
    purge_old_access_log($dbh) if defined $keep && rand() < 0.02;
}

# 保持日数より古いアクセスログを掃除する（ついで掃除。テーブル肥大化を防ぐ）。
sub purge_old_access_log {
    my ($dbh) = @_;
    my $keep = PJJ::conf('access_log_keep_days');
    return unless defined $keep;
    eval {
        $dbh->do('DELETE FROM access_log WHERE accessed_at < now() - make_interval(days => ?)',
            undef, $keep);
        1;
    } or warn "purge_old_access_log failed: $@\n";
}

1;
