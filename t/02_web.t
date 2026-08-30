# PJJ::Web（クエリ・ボディ・Cookie の読み取り、JSON 応答、ベース URL）。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 19;
use PJJ;
# Test::More も fail() を輸出するので、衝突しないよう必要なものだけ取り込む
# （fail/respond は子プロセスで動かして確かめる）。
use PJJ::Web qw(query_param query_params get_cookie app_base_url);

my $LIB = "$FindBin::Bin/..";

# respond / fail は exit するので、子プロセスで走らせて出力を見る。
sub run_cgi {
    my ($code, %env) = @_;
    my $script = "$FindBin::Bin/tmp_cgi.pl";
    open my $fh, '>:raw', $script or die $!;
    print $fh "use lib '$LIB';\nuse PJJ;\nuse PJJ::Web;\n$code\n";
    close $fh;
    local %ENV = (%ENV, %env);
    my $out = `$^X $script`;
    unlink $script;
    return $out;
}

# ---- クエリ文字列 ----
{
    local $ENV{QUERY_STRING} = 'action=login&id=42&q=%E5%B9%B4%E8%A1%A8&empty=';
    is(query_param('action'), 'login', 'query_param が値を返す');
    is(query_param('id'), '42', 'query_param が数値も文字列で返す');
    is(query_param('q'), "\x{5e74}\x{8868}", 'query_param が %XX を UTF-8 文字列に戻す');
    is(query_param('empty'), '', '値なしのパラメータは空文字');
    is(query_param('nope'), undef, '無いパラメータは undef');
}
{
    local $ENV{QUERY_STRING} = 'tag=a&tag=%E7%8A%AC&other=1';
    is_deeply([query_params('tag')], ['a', "\x{72ac}"], 'query_params が同名を全部返す');
    is_deeply([query_params('none')], [], '該当なしなら空リスト');
}
{
    local $ENV{QUERY_STRING} = 'q=a+b';
    is(query_param('q'), 'a b', '+ が空白に戻る');
}

# ---- Cookie ----
{
    local $ENV{HTTP_COOKIE} = 'foo=1; nenpyo_sid=deadbeef; bar=2';
    is(get_cookie('nenpyo_sid'), 'deadbeef', 'get_cookie が値を返す');
    is(get_cookie('missing'), undef, '無い Cookie は undef');
}

# ---- ベース URL ----
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x');
    local $ENV{HTTP_HOST}   = 'nenpyo.peanutsjamjam.jp';
    local $ENV{SCRIPT_NAME} = '/api.cgi';
    local $ENV{HTTPS}       = 'on';
    is(app_base_url(), 'https://nenpyo.peanutsjamjam.jp/', '未設定ならリクエストから組み立てる');
}
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x', base_url => 'https://example.test/app');
    local $ENV{HTTP_HOST} = 'attacker.example';
    is(app_base_url(), 'https://example.test/app/',
       'base_url を設定すると Host ヘッダを無視し、末尾スラッシュを補う');
}

# ---- JSON 応答 ----
{
    my $out = run_cgi(q{PJJ->init(cookie_name=>'x'); respond({ ok => JSON::PP::true });});
    like($out, qr{^Status: 200 OK\r\n},                    'respond の既定は 200 OK');
    like($out, qr{Content-Type: application/json; charset=utf-8}, 'Content-Type が JSON');
    like($out, qr{\{"ok":true\}$},                         'ボディが JSON');
    unlike($out, qr{Cache-Control},                        '既定では Cache-Control を付けない');
}
{
    my $out = run_cgi(q{PJJ->init(cookie_name=>'x', cache_control=>'no-store'); respond({});});
    like($out, qr{Cache-Control: no-store},                'cache_control を設定すると付く');
}
{
    my $out = run_cgi(q{PJJ->init(cookie_name=>'x'); fail('email_required');});
    like($out, qr{^Status: 400 Bad Request\r\n},           'fail の既定は 400');
}
{
    my $out = run_cgi(q{PJJ->init(cookie_name=>'x'); fail('nope','404 Not Found',{field=>'x'});});
    like($out, qr{"error":"nope".*"params":\{"field":"x"\}}s, 'fail は params も返す');
}
