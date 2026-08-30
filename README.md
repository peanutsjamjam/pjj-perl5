# PJJ — peanutsjamjam の Perl 共通ライブラリ

nenpyo / wslfan / zigsaw / jammemo の `api.cgi` が共通で使う、サインアップ・サインイン
まわりの土台をまとめたもの。各アプリに同じコードを書き写すのをやめ、ここ1か所で直す。

## 置き場所

| 環境 | パス | 中身 |
|---|---|---|
| 開発 | `/home/sugawara/lib/perl5` | このリポジトリの作業用チェックアウト |
| 本番 | `/var/lib/perl5` | GitHub から clone したもの（全アプリで共有） |

本番は `/var/jp.peanutsjamjam.<app>/html` の外にあるので、Web からは読めない。

```
# 本番への初回導入
sudo mkdir -p /var/lib/perl5 && sudo chown sugawara:sugawara /var/lib/perl5
git clone https://github.com/peanutsjamjam/pjj-perl5.git /var/lib/perl5
# 更新
git -C /var/lib/perl5 pull
```

## api.cgi からの読み込み

`use` はコンパイル時に解決されるので、`@INC` への追加は `BEGIN` の中で行う。
探索順は `$ENV{PJJ_LIB}`（テスト用）→ `$main::PJJ_LIB`（`env.pl`）→ `/var/lib/perl5`
→ `/home/sugawara/lib/perl5`。dev と本番は同じサーバー上にあり両方のパスが存在するため、
**どちらを使うかは `env.pl` で明示する**こと。

```perl
our $PJJ_LIB;
BEGIN {
    my $env_file = File::Basename::dirname(__FILE__) . '/env.pl';
    require $env_file if -f $env_file;
    my ($lib) = grep { defined && length && -d } (
        $ENV{PJJ_LIB}, $PJJ_LIB, '/var/lib/perl5', '/home/sugawara/lib/perl5');
    die "PJJ library not found\n" unless $lib;
    unshift @INC, $lib;
}
use PJJ;
use PJJ::Web;
use PJJ::Session;
```

`env.pl`（git 管理外）に環境ごとのパスを書く:

```perl
$main::PJJ_LIB = '/home/sugawara/lib/perl5';   # dev
$main::PJJ_LIB = '/var/lib/perl5';             # 本番
```

## 初期化

アプリごとの違いは、すべて `PJJ->init` の引数で吸収する。

```perl
PJJ->init(
    app          => 'nenpyo',                    # メールの From・件名・本文に出る表示名
    db           => 'nenpyo',                    # dbi:Pg:dbname=<これ>
    cookie_name  => 'nenpyo_sid',                # セッション Cookie 名
    mail_from    => 'nenpyo@peanutsjamjam.jp',
    user_columns => ['is_guest'],                # current_user が追加で引く users の列
);
```

| キー | 既定 | 意味 |
|---|---|---|
| `app` | `'app'` | 表示名。メールの From / 件名 / 本文に差し込む |
| `db` | なし | PostgreSQL の DB 名 |
| `cookie_name` | なし | セッション Cookie の名前 |
| `cookie_path` | 自動 | 未指定なら `SCRIPT_NAME` のディレクトリ部 |
| `session_days` | 30 | セッションの有効日数 |
| `pbkdf2_iter` | 120000 | PBKDF2 の反復回数（既存ハッシュと揃えること） |
| `signup_token_hours` | 1 | 登録用リンクの有効時間 |
| `reset_token_hours` | 1 | 再設定用リンクの有効時間 |
| `mail_from` | なし | 確認メールの差出人アドレス |
| `sendmail` | `/usr/sbin/sendmail` | sendmail のパス（テストで偽物に差し替える） |
| `base_url` | なし | 設定するとメール内リンクが Host ヘッダに依存しなくなる |
| `max_body_bytes` | なし | リクエストボディの上限（超過は 413） |
| `cache_control` | なし | 応答に付ける `Cache-Control` |
| `user_columns` | `[]` | `current_user` が `users` から追加で引く列 |
| `access_log_keep_days` | なし | アクセスログの保持日数（未設定なら自動削除しない） |

`PJJ::Auth` を使うときは、さらに次を渡してアプリごとの違いを吸収する。

| キー | 既定 | 意味 |
|---|---|---|
| `body_format` | `'json'` | リクエストボディの形式。`'json'` か `'form'`（wslfan は `'form'`） |
| `auth_actions` | 全部 | 受け付ける action の配列。持っていないテーブルに触らせないために絞る |
| `account_json` | `{username,email}` | `sub { my ($u) = @_; ... }` アカウント応答の形（`is_admin` / `guest` はここで足す） |
| `signup_link` | `?signup=<t>` | `sub { my ($token) = @_; ... }` メール内の登録リンク |
| `reset_link` | `?reset=<t>` | `sub { my ($token) = @_; ... }` メール内の再設定リンク |
| `login_link` | ベース URL | `sub { ... }` 「既にアカウントがあります」案内メールのリンク |
| `rate_limit` | なし | `{login_window_min, login_max_per_email, login_max_per_ip, mail_window_min, mail_max_per_email, mail_max_per_ip}` |
| `signup_create_user` | INSERT | `sub { my ($dbh, $a) = @_; ... }` ユーザー作成（nenpyo のゲスト昇格用） |
| `reset_eligible` | 全員 | `sub { my ($u) = @_; ... }` 再設定を受け付けるユーザーか（nenpyo はゲストを除く） |
| `on_login` | なし | `sub { my ($dbh, $u) = @_; ... }` ログイン成功後の追加処理 |
| `password_min` / `password_max` / `username_max` | 4 / 128 / 50 | 入力の長さ制限 |

## モジュール

| モジュール | 主な関数 |
|---|---|
| `PJJ` | `init` / `conf` — 設定 |
| `PJJ::Web` | `respond` `fail` `add_header` `query_param` `query_params` `read_body_json` `body_raw` `body_param` `get_cookie` `app_base_url` |
| `PJJ::Crypt` | `random_hex` `pbkdf2` `const_eq` |
| `PJJ::DB` | `db` `pgbool` |
| `PJJ::Session` | `set_session_cookie` `clear_session_cookie` `start_session` `current_user` `require_user` `purge_expired_sessions` `purge_expired_signup_tokens` `purge_expired_reset_tokens` |
| `PJJ::Mail` | `mime_word` `send_mail` `send_signup_email` `send_reset_email` `send_signup_exists_email` |
| `PJJ::RateLimit` | `rate_count` `rate_add` `rate_clear` `purge_old_rate_events` |
| `PJJ::AccessLog` | `log_access` `purge_old_access_log` |
| `PJJ::Auth` | `auth_dispatch` — サインアップ／サインインのエンドポイントそのもの |

`respond` と `fail` は応答を書き出して `exit` するので、呼んだ先から戻ってこない。

### 認証エンドポイント（PJJ::Auth）

`auth_dispatch` は次の 11 個を引き受ける。担当する action なら応答して `exit` し、
担当外なら偽を返すので、そのままアプリ固有のルーティングへ進んでよい。

```perl
    my $dbh = db();
    auth_dispatch($dbh, $action, $method);   # 認証系ならここで応答して終わる
    if ($action eq 'teams' && $method eq 'GET') { ... }   # 以降はアプリ固有
```

| action | メソッド | 内容 |
|---|---|---|
| `signup_request` | POST | 確認リンクをメールで送る（まだ作らない） |
| `signup_verify` | GET | リンクの有効性を確かめ email を返す |
| `signup_complete` | POST | 登録してログイン状態に（重複は 409 `duplicate`） |
| `login` | POST | ログイン |
| `logout` | POST | ログアウト |
| `me` | GET | ログイン中のアカウント（未ログインは 401） |
| `change_password` | POST | パスワード変更 |
| `reset_request` | POST | 再設定リンクをメールで送る |
| `reset_verify` | GET | リンクの有効性を確かめ email を返す |
| `reset_complete` | POST | 新パスワードを設定し、既存セッションを全て切って入り直す |
| `account` | DELETE | 退会 |

メールアドレスの存在は常に秘匿する。登録済みでも未登録でも同じ応答を返し、登録済みには
リンクの代わりに「既にアカウントがあります」の案内を送る。ログインはユーザーが居なくても
ダミーで PBKDF2 を回し、応答時間からの列挙も防ぐ。

### 前提とするテーブル

`users` (id, username, email, password_hash, salt, iterations) /
`sessions` (token, user_id, expires_at) /
`signup_tokens` (token, email, expires_at) /
`reset_tokens` (token, user_id, expires_at) は各アプリの `ddl/` にある。
`PJJ::RateLimit` は `rate_events`、`PJJ::AccessLog` は `access_log` を使う。

## テスト

```
cd /home/sugawara/lib/perl5
/usr/local/bin/prove t          # 全部
/usr/local/bin/prove -v t/04_mail.t
```

DB も実メールも使わない。`PJJ::Crypt` は RFC 6070 と同じ形の PBKDF2-HMAC-SHA256 の
既知テストベクタで検証しているので、既存アカウントのハッシュとの互換が担保される。

`PJJ::Auth` のエンドポイントの中身は DB が要るので、ここでは振り分け・リンク書式・応答の形
だけを見る。実際の通し確認は **zigsaw の `t/`（353 件）** が担っている（本物の DB・メールには
触れないサンドボックスで api.cgi を CGI として直接実行する）。ライブラリを直したら
`cd ~/public_html/zigsaw && /usr/local/bin/prove t` も流すこと。

なお `Test::More` も `fail()` を輸出するため、テストから `PJJ::Web` を丸ごと取り込むと
プロトタイプの衝突が出る。テスト側では必要な関数だけ名前を挙げて取り込むこと。

## 使う側

- [nenpyo](https://github.com/peanutsjamjam/nenpyo)
- [wslfan](https://github.com/peanutsjamjam/wslfan)
- [zigsaw](https://github.com/peanutsjamjam/zigsaw-web)
- [jammemo](https://github.com/peanutsjamjam/jammemo)
