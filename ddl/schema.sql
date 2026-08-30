-- PJJ::* が前提とするテーブル定義。
--
--   psql -d <あなたのDB> -f ddl/schema.sql
--
-- users / sessions は必須。signup_tokens / reset_tokens はサインアップとパスワード再設定を
-- 使うなら必要（PJJ->init の auth_actions で使わないなら省ける）。
-- access_log は PJJ::AccessLog、rate_events は PJJ::RateLimit を使うときだけ要る。
--
-- 列は「PJJ が読み書きするもの」だけを並べてある。アプリ固有の列（is_admin / is_guest など）は
-- users に足したうえで PJJ->init(user_columns => [...]) に列名を渡すこと。

-- ---------------------------------------------------------------- users（必須）
-- アカウント。パスワードは PBKDF2-HMAC-SHA256 のハッシュで保存する。
--   iterations を行ごとに持つのは、後から反復回数を上げても古い行を検証できるようにするため。
CREATE TABLE users (
  id            SERIAL PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  email         TEXT NOT NULL,
  password_hash TEXT NOT NULL,           -- PBKDF2-HMAC-SHA256 (hex)
  salt          TEXT NOT NULL,           -- hex
  iterations    INTEGER NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- メールアドレスは大文字小文字を無視して一意（PJJ は lower(email) で引く）。
CREATE UNIQUE INDEX users_email_lower_uniq ON users (lower(email));

-- ------------------------------------------------------------- sessions（必須）
-- ログインセッション。token をそのまま HttpOnly Cookie に載せる。
--   期限切れ行は PJJ::Session の「ついで掃除」で削除される（cron は不要）。
CREATE TABLE sessions (
  token      TEXT PRIMARY KEY,           -- ランダムトークン (hex)
  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX sessions_user_idx ON sessions (user_id);

-- ------------------------------------------------- signup_tokens（サインアップ用）
-- 「メールを確認してから登録」の 2 段階サインアップで、確認リンクに載せるトークン。
--   この時点ではまだ users に行を作らない（存在しないアドレスでアカウントが増えない）。
CREATE TABLE signup_tokens (
  token      TEXT PRIMARY KEY,           -- ランダム hex
  email      TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX signup_tokens_email_idx ON signup_tokens (lower(email));

-- ------------------------------------------------ reset_tokens（パスワード再設定用）
CREATE TABLE reset_tokens (
  token      TEXT PRIMARY KEY,           -- ランダム hex
  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX reset_tokens_user_idx ON reset_tokens (user_id);

-- ------------------------------------------------- access_log（PJJ::AccessLog 用・任意）
-- リクエストごとに送信元 IP と（ログイン中なら）user_id を 1 行。
--   user_id は ON DELETE SET NULL（アカウント削除後もログは残す）。
--   PJJ->init(access_log_keep_days => 90) を渡すと、保持日数より古い行を
--   log_access のついでに確率的に削除する。accessed_at のインデックスがそれを支える。
CREATE TABLE access_log (
  id          BIGSERIAL PRIMARY KEY,
  user_id     INTEGER REFERENCES users(id) ON DELETE SET NULL,
  ip_addr     INET,
  accessed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX access_log_user_idx ON access_log (user_id);
CREATE INDEX access_log_time_idx ON access_log (accessed_at);

-- ------------------------------------------------ rate_events（PJJ::RateLimit 用・任意）
-- レート制限用のイベント記録。CGI はプロセスをまたいで状態を持てないので DB に置く。
--   action  … 種別（'login_fail' / 'mail_signup' / 'mail_reset'）
--   subject … 判定キー（'email:foo@example.com' や 'ip:203.0.113.1'）
-- 直近 N 分の件数を数えて閾値を超えていたら弾く。古い行は「ついで掃除」で削除する。
CREATE TABLE rate_events (
  id         BIGSERIAL PRIMARY KEY,
  action     TEXT NOT NULL,
  subject    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX rate_events_lookup_idx ON rate_events (action, subject, created_at);

-- ------------------------------------------------------------------- 権限
-- CGI を実行するロール（Apache 経由なら apache、suexec なら実行ユーザ）に権限を与える。
-- 下の <role> を置き換えて実行すること。
--
--   GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO <role>;
--   GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA public TO <role>;
