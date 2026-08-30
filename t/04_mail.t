# PJJ::Mail。偽 sendmail に送らせて、ヘッダと本文を確かめる（実メールは送らない）。
use strict;
use warnings;
use utf8;   # このファイルに日本語リテラルを書くため
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 14;
use MIME::Base64 ();
use PJJ;
use PJJ::Mail;

# テスト名に日本語を使うので出力を UTF-8 に（Wide character 警告を出さない）。
binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my $TMP  = "$FindBin::Bin/tmp_mail";
my $FAKE = "$TMP/sendmail";
my $LOG  = "$TMP/mail.log";

mkdir $TMP unless -d $TMP;
# 受け取った内容をそのままログに書き足すだけの sendmail。
open my $fh, '>', $FAKE or die $!;
print $fh "#!$^X\nopen my \$o, '>>', '$LOG' or die \$!;\nprint \$o do { local \$/; <STDIN> };\nprint \$o \"\\n--- END ---\\n\";\n";
close $fh;
chmod 0755, $FAKE;

sub sent {
    open my $l, '<:raw', $LOG or return '';
    my $c = do { local $/; <$l> };
    close $l;
    return $c;
}
sub clear { unlink $LOG }

# 本文は base64 で送られるので、デコードして中身を見る。
sub body_of {
    my ($raw) = @_;
    my ($b64) = $raw =~ /\r\n\r\n(.*?)\n--- END ---/s;
    return '' unless defined $b64;
    my $t = MIME::Base64::decode_base64($b64);
    utf8::decode($t);
    return $t;
}
sub subject_of {
    my ($raw) = @_;
    my ($enc) = $raw =~ /Subject: =\?UTF-8\?B\?([^?]+)\?=/;
    return '' unless defined $enc;
    my $t = MIME::Base64::decode_base64($enc);
    utf8::decode($t);
    return $t;
}

PJJ::_reset();
PJJ->init(app => 'nenpyo', cookie_name => 'x',
          mail_from => 'nenpyo@peanutsjamjam.jp', sendmail => $FAKE,
          signup_token_hours => 1, reset_token_hours => 2);

# ---- 登録用リンク ----
clear();
ok(send_signup_email('a@example.jp', 'https://example.test/?signup=tok'), '登録メールの送信が成功する');
my $raw = sent();
like($raw, qr/^From: nenpyo <nenpyo\@peanutsjamjam\.jp>/m, 'From に表示名とアドレスが入る');
like($raw, qr/^To: a\@example\.jp/m,                        'To が宛先');
like($raw, qr{Content-Transfer-Encoding: base64},           '本文は base64');
like(subject_of($raw), qr/Your nenpyo sign-up link \/ 【nenpyo】登録用リンクのお知らせ/,
     '件名が英語→日本語の併記');
my $body = body_of($raw);
like($body, qr{https://example\.test/\?signup=tok}, '本文にリンクが入る');
like($body, qr/valid for 1 hour\(s\)/,              '有効時間（英語）が設定値どおり');
like($body, qr/このリンクは 1 時間のみ有効です/,      '有効時間（日本語）が設定値どおり');

# ---- 再設定リンク（有効時間は別設定） ----
clear();
ok(send_reset_email('b@example.jp', 'https://example.test/?reset=tok'), '再設定メールの送信が成功する');
$raw = sent();
like(subject_of($raw), qr/Reset your nenpyo password/, '再設定メールの件名');
like(body_of($raw), qr/valid for 2 hour\(s\)/, '再設定リンクは reset_token_hours を使う');

# ---- 既に登録済みの案内 ----
clear();
ok(send_signup_exists_email('c@example.jp', 'https://example.test/'), '案内メールの送信が成功する');
$raw = sent();
like(subject_of($raw), qr/About your nenpyo account/, '案内メールの件名');
unlike(body_of($raw), qr/signup=/, '案内メールには登録リンクを載せない');

clear();
unlink $FAKE;
rmdir $TMP;
