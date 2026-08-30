# PJJ::Crypt（乱数・PBKDF2・定数時間比較）。
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 9;
use PJJ::Crypt;

# RFC 6070 と同じ形の PBKDF2-HMAC-SHA256 テストベクタ
# （password="password", salt="salt"(=73616c74), dkLen=32）。
# 既存アカウントのハッシュと互換であることを、外部の既知値で担保する。
is(pbkdf2('password', '73616c74', 1),
   '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
   'PBKDF2-HMAC-SHA256 c=1 が既知のテストベクタと一致する');
is(pbkdf2('password', '73616c74', 2),
   'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
   'PBKDF2-HMAC-SHA256 c=2 が既知のテストベクタと一致する');

# 同じ入力なら何度でも同じ、salt が違えば別物。
is(pbkdf2('pw', 'aabb', 10), pbkdf2('pw', 'aabb', 10), '同じ入力なら同じハッシュ');
isnt(pbkdf2('pw', 'aabb', 10), pbkdf2('pw', 'ccdd', 10), 'salt が違えば別のハッシュ');

# 日本語パスワード（内部の UTF-8 フラグの有無で結果が変わらないこと）。
my $wide = "\x{3042}\x{3044}";      # あい（文字列）
my $byte = $wide; utf8::encode($byte);   # 同じ内容のバイト列
is(pbkdf2($wide, 'aabb', 10), pbkdf2($byte, 'aabb', 10),
   '日本語パスワードは UTF-8 フラグの有無で結果が変わらない');

ok(const_eq('abc', 'abc'), 'const_eq: 一致は真');
ok(!const_eq('abc', 'abd'), 'const_eq: 不一致は偽');
ok(!const_eq('abc', 'abcd'), 'const_eq: 長さ違いは偽');

like(random_hex(16), qr/^[0-9a-f]{32}$/, 'random_hex(16) は 32 桁の hex');
