package PJJ;
# peanutsjamjam の各アプリ（nenpyo / wslfan / zigsaw / jammemo）が共通で使う
# サインアップ・サインインまわりの土台。
#
# 使い方: api.cgi の先頭で1度だけ PJJ->init(...) を呼び、以降は各モジュールが
# エクスポートする関数をそのまま使う。設定値は全モジュールがここから読む。
#
#   PJJ->init(
#       app         => 'nenpyo',                   # メール文面・From に出る表示名
#       db          => 'nenpyo',                   # PostgreSQL の DB 名
#       cookie_name => 'nenpyo_sid',               # セッション Cookie の名前
#       mail_from   => 'nenpyo@peanutsjamjam.jp',  # 確認メールの差出人
#       user_columns => ['is_guest'],              # current_user が追加で引く列
#   );
#
# 設定は PJJ::conf('cookie_name') で読める（未設定なら既定値）。

use strict;
use warnings;

our $VERSION = '0.01';

# 既定値。init で上書きしなかったキーはこの値になる。
my %DEFAULT = (
    app                => 'app',        # 表示名（メールの From / 件名 / 本文に出る）
    db                 => undef,        # dbi:Pg:dbname=<ここ>
    cookie_name        => undef,        # セッション Cookie 名（必須）
    cookie_path        => undef,        # 未指定なら SCRIPT_NAME のディレクトリ部から自動判定
    session_days       => 30,           # セッションの有効日数
    pbkdf2_iter        => 120_000,      # PBKDF2 の反復回数（既存ハッシュと揃えること）
    signup_token_hours => 1,            # 登録用リンクの有効時間
    reset_token_hours  => 1,            # 再設定用リンクの有効時間
    mail_from          => undef,        # 差出人アドレス
    sendmail           => '/usr/sbin/sendmail',   # sendmail のパス（テストで差し替える）
    base_url           => undef,        # アプリのベース URL。未設定ならリクエストから組み立てる
    max_body_bytes     => undef,        # リクエストボディの上限（undef = 無制限）
    cache_control      => undef,        # 応答に付ける Cache-Control（undef = 付けない）
    user_columns       => [],           # current_user が users から追加で引く列（is_guest 等）
    access_log_keep_days => undef,      # アクセスログの保持日数（undef = 自動削除しない）

    # ---- PJJ::Auth（認証エンドポイント）用 ----------------------------------
    body_format        => 'json',       # リクエストボディの形式。'json' か 'form'
    auth_actions       => undef,        # 受け付ける action の配列（undef = 全部）
    password_min       => 4,            # パスワードの最小長
    password_max       => 128,          # パスワードの最大長
    username_max       => 50,           # ユーザー名の最大長
    account_json       => undef,        # sub { my ($u) = @_; ... } アカウント応答の作り方
    signup_link        => undef,        # sub { my ($token) = @_; ... } 登録リンク
    reset_link         => undef,        # sub { my ($token) = @_; ... } 再設定リンク
    login_link         => undef,        # sub { ... } 既存アカウント案内メールのリンク
    rate_limit         => undef,        # { login_window_min, login_max_per_email, ... }（undef = 無し）
    signup_create_user => undef,        # sub { my ($dbh, $a) = @_; ... } 既定は users へ INSERT
    reset_eligible     => undef,        # sub { my ($u) = @_; ... } 再設定を受け付けるユーザーか
    on_login           => undef,        # sub { my ($dbh, $u) = @_; ... } ログイン成功後の追加処理
);

my %CONF = %DEFAULT;

# 設定を流し込む。PJJ->init(...) でも PJJ::init(...) でも呼べる。
sub init {
    shift if @_ && defined $_[0] && $_[0] eq __PACKAGE__;
    my %opt = @_;
    for my $k (keys %opt) {
        die "PJJ::init: unknown option '$k'\n" unless exists $DEFAULT{$k};
        $CONF{$k} = $opt{$k};
    }
    # Cookie の Path は配信パスに合わせて自動判定する（環境ごとに固定値を持たない）。
    # SCRIPT_NAME から api.cgi を除いたディレクトリ部を使う。
    #   dev : /~sugawara/nenpyo/api.cgi -> /~sugawara/nenpyo/
    #   本番: /api.cgi                  -> /
    unless (defined $CONF{cookie_path} && length $CONF{cookie_path}) {
        my $path = $ENV{SCRIPT_NAME} || '/';
        $path =~ s#/[^/]*$#/#;
        $path = '/' if $path eq '';
        $CONF{cookie_path} = $path;
    }
    return 1;
}

# 設定値を読む。
sub conf {
    my ($key) = @_;
    die "PJJ::conf: unknown key '$key'\n" unless exists $DEFAULT{$key};
    return $CONF{$key};
}

# テスト用: 設定を既定値に戻す。
sub _reset { %CONF = %DEFAULT; }

1;
