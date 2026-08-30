package PJJ::RateLimit;
# 総当たり・メール爆撃の抑止。(action, subject) の組で直近の件数を数える。
# subject は 'email:foo@example.com' / 'ip:203.0.113.1' のように種別を前置した文字列。
#
# 必要なテーブル（ddl/rate_events.sql）:
#   rate_events (id, action TEXT, subject TEXT, created_at TIMESTAMPTZ DEFAULT now())
#
# 記録に失敗してもリクエスト自体は止めない（warn のみ）。

use strict;
use warnings;
use Exporter ();

our @ISA    = ('Exporter');
our @EXPORT = qw(rate_count rate_add rate_clear purge_old_rate_events);

# 直近 $minutes 分の (action, subject) 件数を数える。
sub rate_count {
    my ($dbh, $action, $subject, $minutes) = @_;
    my ($n) = $dbh->selectrow_array(
        'SELECT count(*) FROM rate_events
          WHERE action = ? AND subject = ? AND created_at > now() - make_interval(mins => ?)',
        undef, $action, $subject, $minutes
    );
    return $n || 0;
}

sub rate_add {
    my ($dbh, $action, $subject) = @_;
    eval { $dbh->do('INSERT INTO rate_events (action, subject) VALUES (?, ?)', undef, $action, $subject); 1 }
        or warn "rate_add failed: $@\n";
}

# 成功したときに失敗記録を消す（正規利用者が締め出されないように）。
sub rate_clear {
    my ($dbh, $action, $subject) = @_;
    eval { $dbh->do('DELETE FROM rate_events WHERE action = ? AND subject = ?', undef, $action, $subject); 1 }
        or warn "rate_clear failed: $@\n";
}

# 古いレートイベントを掃除する（ついで掃除）。
sub purge_old_rate_events {
    my ($dbh) = @_;
    eval { $dbh->do("DELETE FROM rate_events WHERE created_at < now() - interval '1 day'"); 1 }
        or warn "purge_old_rate_events failed: $@\n";
}

1;
