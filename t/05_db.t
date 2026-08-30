# PJJ::DB の pgbool（接続は伴わない）。
# DBD::Pg は boolean を 't'/'f' で返すことも 1/0 で返すこともあるので、両方を通す。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 9;
use JSON::PP ();
use PJJ::DB qw(pgbool);

is(pgbool('t'),     JSON::PP::true,  "'t' は true");
is(pgbool('true'),  JSON::PP::true,  "'true' は true");
is(pgbool('1'),     JSON::PP::true,  "'1' は true");
is(pgbool(1),       JSON::PP::true,  '数値 1 は true');
is(pgbool('f'),     JSON::PP::false, "'f' は false");
is(pgbool('false'), JSON::PP::false, "'false' は false");
is(pgbool('0'),     JSON::PP::false, "'0' は false");
is(pgbool(''),      JSON::PP::false, '空文字は false');
is(pgbool(undef),   JSON::PP::false, 'undef は false');
