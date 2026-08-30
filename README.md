# PJJ

Perl CGI 向けの、サインアップ／サインインの土台。PostgreSQL に載せて使う。

> A small Perl library that implements email-based signup, login, session cookies,
> password reset and account deletion for CGI applications backed by PostgreSQL.
> Comments and documentation are in Japanese.

4 つの自作 Web アプリの `api.cgi` に同じ認証コードを 4 本ずつ書いてしまったので、
それを 1 か所にまとめたもの。**特定の作りに寄せた小さなライブラリ**であって、
汎用フレームワークではない（[想定しているもの／していないもの](#想定しているものしていないもの)）。

## できること

`PJJ::Auth` の `auth_dispatch()` を 1 行呼ぶと、次のエンドポイントを引き受ける。

| action | メソッド | 内容 |
|---|---|---|
| `signup_request` | POST | 確認リンクをメールで送る（この時点では users に行を作らない） |
| `signup_verify` | GET | リンクのトークンを検証し、対応する email を返す |
| `signup_complete` | POST | アカウントを作成してログイン状態に（重複は 409 `duplicate`） |
| `login` | POST | ログイン |
| `logout` | POST | ログアウト |
| `me` | GET | ログイン中のアカウント（未ログインは 401） |
| `change_password` | POST | パスワード変更 |
| `reset_request` | POST | 再設定リンクをメールで送る |
| `reset_verify` | GET | リンクのトークンを検証し、対応する email を返す |
| `reset_complete` | POST | 新パスワードを設定し、既存セッションを全て切って入り直す |
| `account` | DELETE | 退会 |

部品だけ使うこともできる（`PJJ::Crypt` の PBKDF2 だけ、`PJJ::Web` の CGI 入出力だけ、など）。

## 必要なもの

- Perl 5.32 以降（5.32 と 5.44 で動作確認）
- `DBI` と `DBD::Pg`（**この 2 つだけが非コアモジュール**）
- PostgreSQL 12 以降（`make_interval()` を使う）
- メールを送るなら `sendmail` 互換のコマンド

`JSON::PP` / `Digest::SHA` / `MIME::Base64` / `File::Basename` / `Cwd` はコアなので追加インストールは要らない。

## インストール

CPAN には上げていない。clone して `@INC` に足すだけ。

```sh
git clone https://github.com/peanutsjamjam/pjj-perl5.git /path/to/perl5
psql -d yourdb -f /path/to/perl5/ddl/schema.sql
```

`use` はコンパイル時に解決されるので、`@INC` への追加は `BEGIN` の中で行う。

```perl
use lib '/path/to/perl5';
use PJJ;
use PJJ::Web;
use PJJ::DB;
use PJJ::Session;
use PJJ::Auth;
```

置き場所を環境ごとに変えたいときは、設定ファイルの読み込みごと `BEGIN` に入れる。

```perl
our $PJJ_LIB;
BEGIN {
    require Cwd;   # require は相対パスだと @INC を探すので絶対パスにする
    my $env = Cwd::abs_path(File::Basename::dirname(__FILE__)) . '/env.pl';
    require $env if -f $env;      # env.pl の中で $main::PJJ_LIB = '...';
    my ($lib) = grep { defined && length && -d } ($ENV{PJJ_LIB}, $PJJ_LIB, '/var/lib/perl5');
    die "PJJ library not found\n" unless $lib;
    unshift @INC, $lib;
}
```

> **開発機と本番が同じホストにある場合の注意**: 候補パスが両方存在すると、意図しない方を
> 読んでしまう。フォールバック任せにせず、環境ごとの設定で明示すること。

## 使いかた

`api.cgi` の全体像。認証以外のエンドポイントは `auth_dispatch` の後ろに書く。

```perl
#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib '/path/to/perl5';
use PJJ;
use PJJ::Web;
use PJJ::DB;
use PJJ::Auth;

PJJ->init(
    app         => 'My App',                # メールの From / 件名 / 本文に出る表示名
    db          => 'myapp',                 # dbi:Pg:dbname=<これ>
    cookie_name => 'myapp_sid',             # セッション Cookie の名前
    mail_from   => 'noreply@example.com',
);

my $method = uc($ENV{REQUEST_METHOD} || 'GET');
my $action = query_param('action') || '';

eval {
    my $dbh = db();

    # 認証系ならここで応答して終わる。担当外なら偽を返すので下へ進む。
    auth_dispatch($dbh, $action, $method);

    if ($action eq 'items' && $method eq 'GET') {
        my $u = require_user($dbh);         # PJJ::Session
        respond({ items => [ ... ] });
    }
    fail('not_found', '404 Not Found');
    1;
} or do {
    warn "api error: " . ($@ || 'unknown') . "\n";   # 詳細はサーバーログへ
    fail('server_error', '500 Internal Server Error');
};
```

`respond` と `fail` は応答を書き出して `exit` するので、**呼んだ先から戻ってこない**。

### リクエストとレスポンス

ボディは JSON（既定）か `application/x-www-form-urlencoded`（`body_format => 'form'`）。
応答は常に JSON で、エラーは `{"error":"<コード>"}`。コードは翻訳しやすいよう固定文字列にしてある
（`email_required` / `email_invalid` / `invalid_credentials` / `signup_token_invalid` /
`reset_token_invalid` / `password_too_short` / `password_too_long` / `username_length` /
`current_password_wrong` / `not_authenticated` / `too_many_attempts` / `mail_failed` など）。

```sh
curl -c jar -H 'Content-Type: application/json' \
     -d '{"email":"a@example.com","password":"secret"}' \
     'https://example.com/api.cgi?action=login'
# => {"email":"a@example.com","username":"alice"}

curl -b jar 'https://example.com/api.cgi?action=me'
```

## 設定（`PJJ->init`）

| キー | 既定 | 意味 |
|---|---|---|
| `app` | `'app'` | 表示名。メールの From / 件名 / 本文に差し込む |
| `db` | なし | PostgreSQL の DB 名 |
| `cookie_name` | なし | セッション Cookie の名前 |
| `cookie_path` | 自動 | 未指定なら `SCRIPT_NAME` のディレクトリ部から判定 |
| `session_days` | 30 | セッションの有効日数 |
| `pbkdf2_iter` | 120000 | PBKDF2 の反復回数（**既存ハッシュと揃えること**） |
| `signup_token_hours` / `reset_token_hours` | 1 | リンクの有効時間 |
| `mail_from` | なし | 確認メールの差出人アドレス |
| `sendmail` | `/usr/sbin/sendmail` | sendmail のパス（テストで偽物に差し替える） |
| `base_url` | なし | 設定するとメール内リンクが `Host` ヘッダに依存しなくなる |
| `max_body_bytes` | なし | リクエストボディの上限（超過は 413） |
| `cache_control` | なし | 応答に付ける `Cache-Control` |
| `user_columns` | `[]` | `users` から追加で引く列（`is_admin` など） |
| `access_log_keep_days` | なし | アクセスログの保持日数（未設定なら自動削除しない） |

`PJJ::Auth` を使うときは、アプリごとの違いを次で吸収する。

| キー | 既定 | 意味 |
|---|---|---|
| `body_format` | `'json'` | `'json'` か `'form'` |
| `auth_actions` | 全部 | 受け付ける action の配列。**持っていないテーブルに触らせないために絞る** |
| `account_json` | `{username,email}` | `sub { my ($u) = @_; ... }` アカウント応答の形 |
| `signup_link` | `?signup=<t>` | `sub { my ($token) = @_; ... }` メール内の登録リンク |
| `reset_link` | `?reset=<t>` | `sub { my ($token) = @_; ... }` メール内の再設定リンク |
| `login_link` | ベース URL | `sub { ... }` 「既にアカウントがあります」案内メールのリンク |
| `rate_limit` | なし | `{login_window_min, login_max_per_email, login_max_per_ip, mail_window_min, mail_max_per_email, mail_max_per_ip}` |
| `signup_create_user` | INSERT | `sub { my ($dbh, $a) = @_; ...; return $uid }` ユーザー作成の差し替え |
| `reset_eligible` | 全員 | `sub { my ($u) = @_; ... }` 再設定を受け付けるユーザーか |
| `on_login` | なし | `sub { my ($dbh, $u) = @_; ... }` ログイン成功後の追加処理 |
| `password_min` / `password_max` / `username_max` | 4 / 128 / 50 | 入力の長さ制限 |

<details>
<summary>差し替えの例</summary>

```perl
PJJ->init(
    app         => 'My App',
    db          => 'myapp',
    cookie_name => 'myapp_sid',
    mail_from   => 'noreply@example.com',

    # users.is_admin を引いて応答に載せる
    user_columns => ['is_admin'],
    account_json => sub {
        my ($u) = @_;
        return { username => $u->{username}, email => $u->{email},
                 is_admin => pgbool($u->{is_admin}) };
    },

    # フロントが HashRouter ならメール内リンクをハッシュ形式に
    signup_link => sub { app_base_url() . "#/signup/$_[0]" },
    reset_link  => sub { app_base_url() . "#/reset/$_[0]"  },
    login_link  => sub { app_base_url() . '#/login' },

    # 総当たり・メール爆撃の抑止（rate_events テーブルが要る）
    rate_limit  => {
        login_window_min => 15, login_max_per_email => 5,  login_max_per_ip => 20,
        mail_window_min  => 60, mail_max_per_email  => 3,  mail_max_per_ip  => 10,
    },
);
```
</details>

## モジュール

| モジュール | 主な関数 |
|---|---|
| `PJJ` | `init` `conf` — 設定 |
| `PJJ::Web` | `respond` `fail` `add_header` `query_param` `query_params` `read_body_json` `body_raw` `body_param` `get_cookie` `app_base_url` |
| `PJJ::Crypt` | `random_hex` `pbkdf2` `const_eq` |
| `PJJ::DB` | `db` `pgbool` |
| `PJJ::Session` | `set_session_cookie` `clear_session_cookie` `start_session` `current_user` `require_user` `purge_expired_sessions` `purge_expired_signup_tokens` `purge_expired_reset_tokens` |
| `PJJ::Mail` | `mime_word` `send_mail` `send_signup_email` `send_reset_email` `send_signup_exists_email` |
| `PJJ::RateLimit` | `rate_count` `rate_add` `rate_clear` `purge_old_rate_events` |
| `PJJ::AccessLog` | `log_access` `purge_old_access_log` |
| `PJJ::Auth` | `auth_dispatch` — 上記エンドポイントの本体 |

## データベース

`ddl/schema.sql` を流す。`users` と `sessions` が必須、`signup_tokens` / `reset_tokens` は
サインアップと再設定を使うなら必要。`access_log` と `rate_events` は該当モジュールを使うときだけ。

アプリ固有の列（`is_admin` など）は `users` に足して `user_columns` に列名を渡す。

**期限切れ行の掃除に cron は要らない。** ログインや登録の処理のついでに `DELETE` を 1 本打つ
「ついで掃除」で、セッション・各トークンを消す。アクセスログとレートイベントは、毎回打つと
無駄なので確率的に（約 2%）掃除する。

## セキュリティ上の設計

- **パスワード**は PBKDF2-HMAC-SHA256（既定 12 万回）＋行ごとのランダム salt。
  反復回数を `users.iterations` に行ごとに持つので、**後から回数を上げても古い行を検証できる**。
  照合は定数時間比較（`const_eq`）。
- **セッション Cookie** は `HttpOnly; Secure; SameSite=Lax`。トークンは `/dev/urandom` 由来の 32 バイト。
  Cookie の `Path` は `SCRIPT_NAME` から自動判定するので、配信パスが変わっても設定を書き換えなくてよい。
- **メールアドレスの存在を秘匿する。** `signup_request` も `reset_request` も、登録済み／未登録で
  同じ `{ok:true}` を返す。登録済みのアドレスには登録リンクの代わりに「既にアカウントがあります」の
  案内を送るので、**そのアドレスの持ち主だけが事実を知れる**。
- **応答時間からの列挙も防ぐ。** `login` はユーザーが存在しなくてもダミー salt で PBKDF2 を回してから
  401 を返す。ここを省くと「1 回の試行でアドレスの登録有無が分かる」穴になる。
- **パスワード再設定に成功したら、そのユーザーの既存セッションを全て削除**してから入り直す
  （盗まれていた可能性のある古いセッションを切るため）。
- **`base_url` を設定すると `Host` ヘッダに依存しなくなる。** 未設定だとメール内リンクを
  リクエストの `Host` から組み立てるため、Host インジェクションの余地が残る。**本番では設定を推奨**。
- **レート制限は任意。** `rate_limit` を渡すと、ログイン失敗とメール送信を「宛先ごと」「IP ごと」に
  直近 N 分で数えて抑止する。CGI はプロセスをまたいで状態を持てないので DB に置いている。

パスワードの最小長は既定 4 文字と**緩い**。実運用では `password_min` を上げること。

## テスト

```sh
prove t          # 91 件。DB も実メールも使わない
prove -v t/04_mail.t
```

`PJJ::Crypt` は **RFC 6070 と同じ形の PBKDF2-HMAC-SHA256 既知テストベクタ**で検証しているので、
実装を変えても既存アカウントのハッシュとの互換が壊れていないことを確認できる。

DB を伴うエンドポイントの通し確認は、このリポジトリには入っていない
（利用側アプリの結合テストで行っている）。

> **テストを書くときの注意**: `Test::More` も `fail()` を輸出するので、`PJJ::Web` を丸ごと
> `use` するとプロトタイプ衝突の警告が出る。テスト側では必要な関数だけ名前を挙げて取り込む。

## 想定しているもの／していないもの

**想定している**

- 1 リクエスト 1 プロセスの CGI（`respond`/`fail` が `exit` する前提）
- PostgreSQL
- メール確認つきのサインアップと、Cookie セッション

**想定していない**

- mod_perl / PSGI などの永続プロセス（設定はプロセス内グローバルで、リクエストごとに `init` する作り）
- MySQL / SQLite（SQL は PostgreSQL 方言）
- OAuth・2 要素認証・CSRF トークン（**CSRF は `SameSite=Lax` に頼っている**）
- CPAN 配布（`Makefile.PL` は無い）

## 由来

作者の 4 つの Web アプリ（[nenpyo](https://github.com/peanutsjamjam/nenpyo) ほか）から
共通部分を抜き出したもの。**その 4 つの都合に合わせて作ってある**ので、API は必要に応じて
予告なく変えることがある。使う場合はコミットを固定するか fork を推奨。

## ライセンス

MIT License（[LICENSE](LICENSE)）
