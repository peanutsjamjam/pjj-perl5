package PJJ::Mail;
# 確認メールの送信。件名・本文は同じ内容を英語→日本語の順で併記する。
# アプリ名（PJJ->init(app => ...)）だけを差し替えて、3種類の文面を組み立てる。
#
# 宛先 $to は呼び出し前に書式検証済み（改行・空白なし）であること。
# 送信失敗時は 0 を返す（呼び出し側で扱う）。詳細はサーバーログ（warn）へ。

use strict;
use warnings;
use utf8;
use MIME::Base64 ();
use Exporter ();
use PJJ ();

our @ISA    = ('Exporter');
our @EXPORT = qw(mime_word send_mail send_signup_email send_reset_email send_signup_exists_email);

my $RULE = "\n----------------------------------------\n\n";

# 日本語のヘッダ値（Subject 等）を MIME エンコードワードにする。
sub mime_word {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    return '=?UTF-8?B?' . MIME::Base64::encode_base64($s, '') . '?=';
}

# メール1通を送る。件名・本文とも UTF-8 の文字列で渡す。
sub send_mail {
    my ($to, $subject, $body) = @_;
    my $app  = PJJ::conf('app');
    my $from = PJJ::conf('mail_from');
    my $sendmail = PJJ::conf('sendmail');
    utf8::encode($body) if utf8::is_utf8($body);
    my $ok = eval {
        open(my $mh, '|-', $sendmail, '-t', '-i') or die "sendmail: $!";
        print $mh "From: $app <$from>\r\n";
        print $mh "To: $to\r\n";
        print $mh "Subject: " . mime_word($subject) . "\r\n";
        print $mh "MIME-Version: 1.0\r\n";
        print $mh "Content-Type: text/plain; charset=\"UTF-8\"\r\n";
        print $mh "Content-Transfer-Encoding: base64\r\n";
        print $mh "\r\n";
        print $mh MIME::Base64::encode_base64($body);
        close($mh) or die "sendmail close: $!";
        1;
    };
    warn "send_mail failed: $@\n" unless $ok;
    return $ok ? 1 : 0;
}

# 登録用リンクのメール。
sub send_signup_email {
    my ($to, $url) = @_;
    my $app   = PJJ::conf('app');
    my $hours = PJJ::conf('signup_token_hours');
    return send_mail($to,
        "Your $app sign-up link / 【$app】登録用リンクのお知らせ",
        "Thank you for signing up for $app.\n"
      . "Open the link below and set your username and password to complete your registration.\n"
      . "(This link is valid for ${hours} hour(s) only.)\n\n"
      . "$url\n\n"
      . "If you did not request this email, please ignore it.\n"
      . $RULE
      . "$app への登録ありがとうございます。\n"
      . "下記のリンクを開き、ユーザー名とパスワードを設定すると登録が完了します。\n"
      . "（このリンクは ${hours} 時間のみ有効です）\n\n"
      . "$url\n\n"
      . "このメールに心当たりがない場合は、破棄してください。\n"
    );
}

# パスワード再設定リンクのメール。
sub send_reset_email {
    my ($to, $url) = @_;
    my $app   = PJJ::conf('app');
    my $hours = PJJ::conf('reset_token_hours');
    return send_mail($to,
        "Reset your $app password / 【$app】パスワード再設定のお知らせ",
        "We received a request to reset your $app password.\n"
      . "Open the link below to set a new password.\n"
      . "(This link is valid for ${hours} hour(s) only.)\n\n"
      . "$url\n\n"
      . "If you did not request this, please ignore this email; your password will not change.\n"
      . $RULE
      . "$app のパスワード再設定のリクエストを受け付けました。\n"
      . "下記のリンクを開いて、新しいパスワードを設定してください。\n"
      . "（このリンクは ${hours} 時間のみ有効です）\n\n"
      . "$url\n\n"
      . "心当たりがない場合は、このメールを破棄してください（パスワードは変更されません）。\n"
    );
}

# 既に登録済みのメールに登録申請が来たときの案内メール。存在の有無を秘匿するため
# API/UI の応答は未登録時と同じ（{ok}→「送信しました」）にし、リンクの代わりにこの案内を送る。
# こうすれば、そのメールの本当の持ち主だけが「既にアカウントがある」ことを知れる。
sub send_signup_exists_email {
    my ($to, $url) = @_;
    my $app = PJJ::conf('app');
    return send_mail($to,
        "About your $app account / 【$app】アカウントについてのお知らせ",
        "Someone (perhaps you) tried to sign up for $app with this email address,\n"
      . "but an account already exists for it.\n"
      . "You can simply log in below. If you forgot your password, use \"Forgot your password?\" on the login screen.\n\n"
      . "$url\n\n"
      . "If this wasn't you, no action is needed; your account is unaffected.\n"
      . $RULE
      . "このメールアドレスで $app への新規登録が試みられましたが、\n"
      . "すでにアカウントが存在します。\n"
      . "下記からそのままログインできます。パスワードをお忘れの場合は、ログイン画面の\n"
      . "「パスワードをお忘れですか？」からパスワードを再設定してください。\n\n"
      . "$url\n\n"
      . "心当たりがない場合は、対応は不要です（アカウントに影響はありません）。\n"
    );
}

1;
