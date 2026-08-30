package PJJ::Crypt;
# 乱数とパスワードハッシュ。api.cgi と ddl/passwd.pl のように、
# 同じ計算を別の場所で書いてしまわないよう1か所にまとめている。

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256);
use Exporter ();

our @ISA    = ('Exporter');
our @EXPORT = qw(random_hex pbkdf2 const_eq);

# 暗号論的乱数を $bytes バイト読み、hex 文字列で返す（セッション・各種トークン用）。
sub random_hex {
    my ($bytes) = @_;
    open my $fh, '<:raw', '/dev/urandom' or die "urandom: $!";
    read($fh, my $buf, $bytes);
    close $fh;
    return unpack('H*', $buf);
}

# PBKDF2-HMAC-SHA256、1 ブロック (32byte) 分。hex を返す。
# $salt_hex は hex 文字列、$iter は反復回数（users.iterations に保存した値）。
sub pbkdf2 {
    my ($password, $salt_hex, $iter) = @_;
    my $salt = pack('H*', $salt_hex);
    utf8::encode($password) if utf8::is_utf8($password);
    my $u   = hmac_sha256($salt . pack('N', 1), $password);
    my $out = $u;
    for (my $i = 1; $i < $iter; $i++) {
        $u = hmac_sha256($u, $password);
        $out ^= $u;
    }
    return unpack('H*', $out);
}

# 一定時間比較（タイミング攻撃緩和）。一致すれば真。
sub const_eq {
    my ($a, $b) = @_;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $r == 0;
}

1;
