# セッション Cookie の組み立てと、リクエストボディの読み取り。
# respond が exit するので、いずれも子プロセスで CGI として動かして出力を確かめる。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 12;

my $LIB    = "$FindBin::Bin/..";
my $SCRIPT = "$FindBin::Bin/tmp_session.pl";
my $BODY   = "$FindBin::Bin/tmp_body";

# $code を CGI として動かし、標準出力を返す。$body があれば標準入力から流し込む。
sub run_cgi {
    my ($code, $env, $body) = @_;
    open my $fh, '>:raw', $SCRIPT or die $!;
    print $fh "use lib '$LIB';\nuse PJJ;\nuse PJJ::Web;\nuse PJJ::Session;\n$code\n";
    close $fh;
    my $redirect = '';
    if (defined $body) {
        open my $bf, '>:raw', $BODY or die $!;
        print $bf $body;
        close $bf;
        $redirect = " < $BODY";
    }
    local %ENV = (%ENV, %$env);
    my $out = `$^X $SCRIPT$redirect`;
    unlink $SCRIPT;
    unlink $BODY if defined $body;
    return $out;
}

my %BASE = (SCRIPT_NAME => '/~sugawara/nenpyo/api.cgi');

# ---- Set-Cookie ----
{
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'nenpyo_sid'); set_session_cookie('abc123'); respond({});},
        \%BASE);
    like($out, qr{Set-Cookie: nenpyo_sid=abc123;}, 'Cookie 名と値が入る');
    like($out, qr{Path=/~sugawara/nenpyo/;},       'Path が配信ディレクトリになる');
    like($out, qr{Max-Age=2592000;},               '既定 30 日ぶんの Max-Age');
    like($out, qr{HttpOnly},                       'HttpOnly が付く');
    like($out, qr{Secure},                         'Secure が付く');
    like($out, qr{SameSite=Lax},                   'SameSite=Lax が付く');
}
{
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x_sid'); set_session_cookie('t', 3); respond({});},
        \%BASE);
    like($out, qr{Max-Age=259200;}, '日数を渡すとその日数の Max-Age になる');
}
{
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x_sid'); clear_session_cookie(); respond({});},
        \%BASE);
    like($out, qr{Set-Cookie: x_sid=; .*Max-Age=0}, 'clear は空値・Max-Age=0');
}

# ---- ボディの読み取り ----
{
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x'); my $b = read_body_json(); respond({ got => $b->{email} });},
        { %BASE, CONTENT_LENGTH => 24 }, '{"email":"a@example.jp"}');
    like($out, qr{"got":"a\@example\.jp"}, 'JSON ボディを読める');
}
{
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x'); respond({ got => body_param('name') });},
        { %BASE, CONTENT_LENGTH => 18 }, 'name=%E7%8A%AC&x=1');
    like($out, qr{"got":"\xe7\x8a\xac"}, 'form ボディを UTF-8 文字列で読める');
}
{
    # CONTENT_LENGTH が上限を超えていたら、読み込む前に 413 で弾く。
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x', max_body_bytes=>10); read_body_json(); respond({});},
        { %BASE, CONTENT_LENGTH => 999 }, 'x' x 999);
    like($out, qr{^Status: 413 Payload Too Large}, '上限超過は 413');
}
{
    # 上限を設定していなければ素通り。
    my $out = run_cgi(
        q{PJJ->init(cookie_name=>'x'); my $b = read_body_json(); respond({ n => scalar keys %$b });},
        { %BASE, CONTENT_LENGTH => 13 }, '{"a":1,"b":2}');
    like($out, qr{"n":2}, '上限未設定ならそのまま読む');
}
