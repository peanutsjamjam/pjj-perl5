package PJJ::DB;
# PostgreSQL への接続と、Pg の boolean を JSON に直す小道具。
#
# 接続は peer 認証（パスワード不要）。dev は suexec で sugawara、本番は apache として
# 実行されるので、どちらのロールにも権限を与えておくこと。

use strict;
use warnings;
use DBI;
use JSON::PP ();
use Exporter ();
use PJJ ();
use PJJ::Web qw(fail);

our @ISA    = ('Exporter');
our @EXPORT = qw(db pgbool);

sub db {
    my $name = PJJ::conf('db');
    die "PJJ::DB::db: db name is not configured (PJJ->init(db => ...))\n"
        unless defined $name && length $name;
    my $dbh = DBI->connect(
        "dbi:Pg:dbname=$name", '', '',
        { RaiseError => 1, AutoCommit => 1, PrintError => 0, pg_enable_utf8 => 1 }
    ) or fail('db_error', '500 Internal Server Error');
    return $dbh;
}

# PostgreSQL の boolean（DBD::Pg は 't'/'f' や 1/0 を返す）を JSON::PP の true/false にする。
sub pgbool {
    my ($v) = @_;
    return JSON::PP::false unless defined $v;
    return JSON::PP::true if $v eq 't' || $v eq '1' || $v eq 'true';
    return JSON::PP::true if !ref($v) && $v =~ /^\d+$/ && $v != 0;
    return JSON::PP::false;
}

1;
