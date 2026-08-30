# PJJ の設定（既定値・上書き・Cookie Path の自動判定）。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 12;
use PJJ;

# 既定値
is(PJJ::conf('session_days'), 30,      '既定 session_days は 30');
is(PJJ::conf('pbkdf2_iter'),  120_000, '既定 pbkdf2_iter は 120000');
is(PJJ::conf('sendmail'), '/usr/sbin/sendmail', '既定 sendmail のパス');
is(PJJ::conf('max_body_bytes'), undef, '既定ではボディ上限なし');
is(PJJ::conf('cache_control'), undef,  '既定では Cache-Control を付けない');

# 上書き
{
    local $ENV{SCRIPT_NAME} = '/~user/myapp/api.cgi';
    PJJ::_reset();
    PJJ->init(app => 'My App', db => 'myapp', cookie_name => 'myapp_sid', session_days => 7);
    is(PJJ::conf('app'),          'My App',     'app を設定できる');
    is(PJJ::conf('session_days'), 7,            'session_days を上書きできる');
    is(PJJ::conf('cookie_path'), '/~user/myapp/', 'Cookie Path を SCRIPT_NAME から自動判定する');
}

# 本番のように SCRIPT_NAME がルート直下でも正しく '/' になる
{
    local $ENV{SCRIPT_NAME} = '/api.cgi';
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid');
    is(PJJ::conf('cookie_path'), '/', '本番配置では Cookie Path が /');
}

# 明示指定は自動判定より優先
{
    local $ENV{SCRIPT_NAME} = '/api.cgi';
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid', cookie_path => '/fixed/');
    is(PJJ::conf('cookie_path'), '/fixed/', 'cookie_path の明示指定が優先される');
}

# 知らないキーは事故のもとなので落とす
eval { PJJ->init(no_such_option => 1) };
like($@, qr/unknown option/, '未知のオプションは die する');
eval { PJJ::conf('no_such_key') };
like($@, qr/unknown key/, '未知のキーの参照は die する');
