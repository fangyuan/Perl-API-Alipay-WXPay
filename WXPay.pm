package WXPay;
use strict;
use warnings;
use utf8;
use MooseX::Singleton;
use Mojo::UserAgent;
use Digest::MD5 qw/md5_hex/;
use XML::Simple;
use HTTP::Request;
use HTTP::Headers;
use LWP::UserAgent;
use Net::SSL;
use Encode;

has config => ( is => 'ro', isa => 'HashRef', required => 1 );
has ua => (
    is      => 'ro',
    isa     => 'LWP::UserAgent',
    lazy    => 1,
    default => sub { LWP::UserAgent->new }
);

sub payment_link_within_page {
    my $self       = shift;
    my $product_id = shift;
    my $params     = {
        appid      => $self->config->{appid},
        mch_id     => $self->config->{mch_id},
        time_stamp => time,
        nonce_str  => $self->__nonce_str,
        product_id => $product_id,
    };
    $params->{sign} = $self->__sign($params);
    my $pay_long_url = sprintf(
        'weixin://wxpay/bizpayurl?%s',
        join(
            '&', map { sprintf( '%s=%s', $_, $params->{$_} ) } keys %$params
        )
    );
    my $pay_short_url = $self->shorturl($pay_long_url) || $pay_long_url;
    return $pay_short_url;
}

sub unified_order {
    my $self   = shift;
    my $params = shift;
    my $api    = 'https://api.mch.weixin.qq.com/pay/unifiedorder';
    return unless $params->{body};
    return unless $params->{out_trade_no};
    return unless $params->{total_fee};
    return unless $params->{notify_url};
    return
      unless $params->{trade_type}
      and $params->{trade_type} =~ /^JSAPI|NATIVE|APP$/;
    $params->{appid}     = $self->config->{appid};
    $params->{mch_id}    = $self->config->{mch_id};
    $params->{nonce_str} = $self->__nonce_str;
    $params->{sign}      = $self->__sign($params);
    return $self->__request( $api, $params );
}

sub order_query {
    my $self   = shift;
    my $params = shift;
    return unless $params->{out_trade_no} || $params->{transaction_id};
    $params->{appid}     = $self->config->{appid};
    $params->{mch_id}    = $self->config->{mch_id};
    $params->{nonce_str} = $self->__nonce_str;
    $params->{sign}      = $self->__sign($params);
    my $api = 'https://api.mch.weixin.qq.com/pay/orderquery';
    return $self->__request( $api, $params );
}

sub order_refund {
    my $self   = shift;
    my $params = shift;
    return unless $params->{out_refund_no};
    return unless $params->{total_fee} and $params->{refund_fee};
    return unless $params->{out_trade_no} || $params->{transaction_id};
    $params->{appid}     = $self->config->{appid};
    $params->{mch_id}    = $self->config->{mch_id};
    $params->{nonce_str} = $self->__nonce_str;
    $params->{op_user_id} ||= $self->config->{mch_id};
    $params->{sign} = $self->__sign($params);
    my $api = 'https://api.mch.weixin.qq.com/secapi/pay/refund';
    return $self->__ssl_request( $api, $params );
}

sub shorturl {
    my $self     = shift;
    my $long_url = shift;
    my $params   = {
        appid     => $self->config->{appid},
        mch_id    => $self->config->{mch_id},
        long_url  => $long_url,
        nonce_str => $self->__nonce_str,
    };
    $params->{sign} = $self->__sign($params);
    my $api = 'https://api.mch.weixin.qq.com/tools/shorturl';
    my $result = $self->__request( $api, $params );
    return $result->{response}->{short_url} if $result->{ok};
    return ( 0, $result->{errmsg} ) if wantarray;
}

sub return_xml {
    my $self   = shift;
    my $params = shift;

    if ( $params->{return_code} eq 'SUCCESS' ) {
        $params->{appid}     = $self->config->{appid};
        $params->{mch_id}    = $self->config->{mch_id};
        $params->{nonce_str} = $self->__nonce_str;
        $params->{sign}      = $self->__sign($params);
    }
    return $self->__create_xml_data($params);
}

sub __request {
    my $self        = shift;
    my $url         = shift;
    my $params      = shift;
    my $request_xml = $self->__create_xml_data($params);
    my $header =
      HTTP::Headers->new( Content_Type => 'text/xml; charset=utf8', );
    my $http_request =
      HTTP::Request->new( POST => $url, $header, $request_xml );
    my $res = $self->ua->request($http_request);
    return $self->__parse_response_with_xml_format( $res->content );
}

sub __ssl_request {
    my $self = shift;
    local $ENV{PERL_NET_HTTPS_SSL_SOCKET_CLASS} = 'Net::SSL';
    local $ENV{HTTPS_PKCS12_FILE}               = $self->config->{sslcert_path};
    local $ENV{HTTPS_PKCS12_PASSWORD}           = $self->config->{mch_id};
    local $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME}    = 0;
    return $self->__request(@_);
}

sub __parse_response_with_xml_format {
    my $self    = shift;
    my $content = shift;
    my $result  = XMLin( $content, ContentKey => '-content' );
    if ( $result->{return_code} eq 'SUCCESS' ) {
        return { ok => 1, response => $result }
          if $self->__valid_response($result);
        return { ok => 0, errmsg => '微信服务器响应验证不通过' };
    }
    return { ok => 0, errmsg => $result->{return_msg} };
}

sub __create_xml_data {
    my $self   = shift;
    my $params = shift || {};
    my $xml    = '<xml>';
    foreach ( keys %$params ) {
        if ( $params->{$_} and $params->{$_} !~ /^\d+$/ ) {
            $xml .= sprintf( '<%s><![CDATA[%s]]></%s>', $_, $params->{$_}, $_ );
        }
        else {
            $xml .= sprintf( '<%s>%s</%s>', $_, $params->{$_}, $_ );
        }
    }
    $xml .= '</xml>';
    return $xml;
}

sub __sign {
    my $self        = shift;
    my $params      = shift || {};
    my $params_sign = {};
    foreach ( keys %$params ) {
        next if $_ eq 'sign';
        next unless defined $params->{$_};
        Encode::_utf8_off( $params->{$_} );
        $params_sign->{$_} = $params->{$_};
    }
    my $sign_string = join( '&',
        map { sprintf( '%s=%s', $_, $params_sign->{$_} ) }
        sort { $a cmp $b } keys %$params_sign );
    $sign_string .= sprintf( '&key=%s', $self->config->{app_key} );
    return uc md5_hex $sign_string;
}

sub __valid_response {
    my $self    = shift;
    my $params  = shift;
    my $sign    = delete $params->{sign};
    my $sign_me = $self->__sign($params);
    return 1 if $sign and $sign eq $sign_me;
    return 0;
}

sub __nonce_str {
    my $self = shift;
    my $len  = shift || 32;
    my @a    = ( "A" .. "Z", 0 .. 9 );
    my $max  = scalar @a - 1;
    return join( "", map { $a[ int( rand($max) ) ] } 1 .. $len );
}

1;
