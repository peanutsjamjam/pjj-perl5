package PJJ::Web;
# CGI の入出力。JSON 応答、クエリ／ボディ／Cookie の読み取り、ベース URL の組み立て。
#
# respond / fail は応答を書き出して exit するので、呼んだ先から戻ってこない。

use strict;
use warnings;
use JSON::PP;
use Exporter ();
use PJJ ();

our @ISA    = ('Exporter');
our @EXPORT = qw(
    add_header respond fail
    query_param query_params read_body_json body_raw body_param
    get_cookie app_base_url
);

my $JSON = JSON::PP->new->utf8->canonical;

# ---- 出力 ------------------------------------------------------------------
# respond のときに一緒に出すヘッダ（Set-Cookie など）。
my @EXTRA_HEADERS;
sub add_header { push @EXTRA_HEADERS, $_[0]; }

# JSON を1件書き出して終了する。$status は "200 OK" のような CGI の Status 行。
sub respond {
    my ($data, $status) = @_;
    $status ||= '200 OK';
    my $body = $JSON->encode($data);
    my $cache = PJJ::conf('cache_control');
    binmode STDOUT;
    print "Status: $status\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n";
    print "Cache-Control: $cache\r\n" if defined $cache && length $cache;
    print "$_\r\n" for @EXTRA_HEADERS;
    print "Content-Length: " . length($body) . "\r\n";
    print "\r\n";
    print $body;
    exit 0;
}

# エラー応答。$code はエラーコード（フロントで i18n 翻訳する）、$params は補間値（任意）。
sub fail {
    my ($code, $status, $params) = @_;
    $status ||= '400 Bad Request';
    my $body = { error => $code };
    $body->{params} = $params if defined $params;
    respond($body, $status);
}

# ---- 入力 ------------------------------------------------------------------
# application/x-www-form-urlencoded 1組を復号する。%XX を戻した時点ではバイト列なので、
# UTF-8 として文字列に直す（非 ASCII を DB(pg_enable_utf8) と突き合わせるのに必要。
# 壊れていればそのまま返す）。
sub _decode_value {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ tr/+/ /;
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    utf8::decode($v);
    return $v;
}

sub query_param {
    my ($name) = @_;
    my $qs = $ENV{QUERY_STRING} || '';
    for my $pair (split /&/, $qs) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && $k eq $name;
        return _decode_value($v);
    }
    return undef;
}

# 同じ名前のクエリパラメータを全部返す（tag=a&tag=b のような複数指定用）。
sub query_params {
    my ($name) = @_;
    my $qs = $ENV{QUERY_STRING} || '';
    my @out;
    for my $pair (split /&/, $qs) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && $k eq $name;
        push @out, _decode_value($v);
    }
    return @out;
}

# リクエストボディを一度だけ読んで返す（生のバイト列）。
my $BODY_CACHE;
sub body_raw {
    return $BODY_CACHE if defined $BODY_CACHE;
    my $length = $ENV{CONTENT_LENGTH} || 0;
    if ($length <= 0) {
        $BODY_CACHE = '';
        return $BODY_CACHE;
    }
    # 読み込む前に上限で弾く（CONTENT_LENGTH を鵜呑みにしてメモリを食い潰さない）。
    # 通常は Apache の LimitRequestBody が先に 413 を返すが、その設定が失われても効くように。
    my $max = PJJ::conf('max_body_bytes');
    fail('payload_too_large', '413 Payload Too Large')
        if defined $max && $length > $max;
    # 大きめのアップロードでも取りこぼさないよう、必要分を読み切る。
    my $raw = '';
    my $got = 0;
    while ($got < $length) {
        my $chunk = '';
        my $n = read(STDIN, $chunk, $length - $got);
        last if !defined $n || $n == 0;
        $raw .= $chunk;
        $got += $n;
    }
    $BODY_CACHE = $raw;
    return $raw;
}

# JSON ボディを読んでハッシュリファレンスで返す。壊れていれば空ハッシュ。
sub read_body_json {
    my $raw = body_raw();
    return {} if $raw eq '';
    my $data = eval { $JSON->decode($raw) };
    return $data && ref($data) eq 'HASH' ? $data : {};
}

# application/x-www-form-urlencoded のボディから名前で値を引く。
sub body_param {
    my ($name) = @_;
    for my $pair (split /&/, body_raw()) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && $k eq $name;
        return _decode_value($v);
    }
    return undef;
}

sub get_cookie {
    my ($name) = @_;
    my $raw = $ENV{HTTP_COOKIE} || '';
    for my $pair (split /;\s*/, $raw) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && $k eq $name;
        return defined $v ? $v : '';
    }
    return undef;
}

# ---- ベース URL ------------------------------------------------------------
# アプリのベース URL（api.cgi のあるディレクトリ、末尾スラッシュ付き）。
# 設定済みの base_url があれば最優先で使う。Host ヘッダに依存しないので、メール内リンク
# （サインアップ/リセット）の Host インジェクションを防げる。
# 未設定時はリクエストの scheme/host から組み立てる（dev でも本番でもその環境に合う）。
sub app_base_url {
    my $configured = PJJ::conf('base_url');
    if (defined $configured && $configured ne '') {
        my $b = $configured;
        $b .= '/' unless $b =~ m#/$#;   # 末尾スラッシュを保証
        return $b;
    }
    my $scheme = ($ENV{HTTPS} && lc $ENV{HTTPS} eq 'on') ? 'https'
               : ($ENV{REQUEST_SCHEME} || 'https');
    my $host = $ENV{HTTP_HOST} || 'localhost';
    my $base = $ENV{SCRIPT_NAME} || '/';
    $base =~ s#/[^/]*$#/#;            # 末尾の api.cgi を取り除く
    return "$scheme://$host$base";
}

# テスト用: 読み込み済みボディと積んだヘッダを捨てる。
sub _reset { undef $BODY_CACHE; @EXTRA_HEADERS = (); }

1;
