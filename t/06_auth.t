# PJJ::Auth のうち、DB を伴わない部分（どの action を担当するか・メール内リンクの書式・
# アカウント応答の形）を確かめる。エンドポイントの中身は zigsaw の t/ が結合テストで通す。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 16;
use JSON::PP ();
use PJJ;
# Test::More も fail() を輸出するので、衝突しないよう必要なものだけ取り込む。
use PJJ::Auth qw(auth_dispatch);

# ---- 担当する action の振り分け ----
# 担当外なら 0 を返す（＝アプリ固有のルーティングへ進んでよい）。$dbh は触られない。
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid');
    is(auth_dispatch(undef, 'teams',  'GET'),  0, '認証と無関係な action は担当しない');
    is(auth_dispatch(undef, '',       'GET'),  0, 'action 無しは担当しない');
    is(auth_dispatch(undef, 'login',  'GET'),  0, 'login は GET では担当しない（POST のみ）');
    is(auth_dispatch(undef, 'me',     'POST'), 0, 'me は POST では担当しない（GET のみ）');
    is(auth_dispatch(undef, 'account','GET'),  0, 'account は GET では担当しない（DELETE のみ）');
}

# auth_actions で絞ると、そこに無い action は担当しない
# （jammemo のように signup_tokens テーブルを持たないアプリのための仕組み）。
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid', auth_actions => [qw(login logout me)]);
    is(auth_dispatch(undef, 'signup_request', 'POST'), 0, 'auth_actions 外の action は担当しない');
    is(auth_dispatch(undef, 'reset_request',  'POST'), 0, 'reset 系も担当しない');
    is(auth_dispatch(undef, 'account',    'DELETE'),   0, '退会も担当しない');
}

# ---- メール内リンクの書式 ----
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid', base_url => 'https://nenpyo.example/');
    is(PJJ::Auth::_signup_link('tok123'), 'https://nenpyo.example/?signup=tok123',
       '既定の登録リンクは ?signup=<token>');
    is(PJJ::Auth::_reset_link('tok123'), 'https://nenpyo.example/?reset=tok123',
       '既定の再設定リンクは ?reset=<token>');
    is(PJJ::Auth::_login_link(), 'https://nenpyo.example/', '既定のログインリンクはベース URL');
}
{
    # wslfan は HashRouter なので "#/..." 形式に差し替える。
    PJJ::_reset();
    PJJ->init(
        cookie_name => 'x_sid',
        base_url    => 'https://wslfan.example/',
        signup_link => sub { "https://wslfan.example/#/signup/$_[0]" },
        reset_link  => sub { "https://wslfan.example/#/reset/$_[0]" },
        login_link  => sub { 'https://wslfan.example/#/login' },
    );
    is(PJJ::Auth::_signup_link('t'), 'https://wslfan.example/#/signup/t', '登録リンクを差し替えられる');
    is(PJJ::Auth::_reset_link('t'),  'https://wslfan.example/#/reset/t',  '再設定リンクを差し替えられる');
    is(PJJ::Auth::_login_link(),     'https://wslfan.example/#/login',    'ログインリンクを差し替えられる');
}

# ---- アカウント応答の形 ----
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid');
    is_deeply(PJJ::Auth::_account_json({ username => 'u', email => 'e', is_admin => 't' }),
              { username => 'u', email => 'e' },
              '既定は username/email だけ（余計な列は出さない）');
}
{
    PJJ::_reset();
    PJJ->init(cookie_name => 'x_sid', account_json => sub {
        my ($u) = @_;
        return { username => $u->{username}, email => $u->{email},
                 is_admin => PJJ::DB::pgbool($u->{is_admin}) };
    });
    is_deeply(PJJ::Auth::_account_json({ username => 'u', email => 'e', is_admin => 't' }),
              { username => 'u', email => 'e', is_admin => JSON::PP::true },
              'アプリごとに応答の形を差し替えられる');
}
