package Alipay;
use strict;
use warnings;
use utf8;
use MooseX::Singleton;
use Mojo::UserAgent;
use Digest::MD5 qw/md5_hex/;
use Data::Dumper;
use Encode;

has config => ( is => 'ro', isa => 'HashRef', required => 1 );
has ua => ( is => 'ro', isa => 'Mojo::UserAgent', lazy => 1, default => sub { Mojo::UserAgent->new } );

sub create_direct_pay_request_params {
    my $self = shift;
    my $params = shift || {};
    return unless $params->{out_trade_no};
    return unless $params->{subject};
    return unless $params->{total_fee};
    $params->{service}        = 'create_direct_pay_by_user';
    $params->{partner}        = $self->config->{seller_id};
    $params->{_input_charset} = 'utf-8';
    $params->{sign_type}      = 'MD5';
    $params->{payment_type}   = 1;
    $params->{seller_id}      = $self->config->{seller_id};
    $params->{paymethod}      = 'directPay';
    $params->{it_b_pay}       = $params->{it_b_pay} || $self->__seconds_to_it_b_pay( $params->{pay_expired_seconds} ) || '1d';
    $params->{sign}           = $self->make_sign($params);
    return $params;
}

sub create_refund_fastpay_request_params {
    my $self         = shift;
    my $batch_no     = shift;
    my $refunds_data = shift;
    return unless $batch_no and $refunds_data;
    my $params       = {};
    my @details_data = map { join( '^', $_->{trade_no}, $_->{amount}, $_->{reason} ); } @$refunds_data;
    my $batch_num    = scalar @details_data;

    $params->{service}        = 'refund_fastpay_by_platform_pwd';
    $params->{partner}        = $self->config->{seller_id};
    $params->{_input_charset} = 'utf-8';
    $params->{sign_type}      = 'MD5';
    $params->{seller_email}   = $self->config->{seller_email};
    $params->{seller_id}      = $self->config->{seller_id};
    $params->{batch_no}       = $batch_no;
    $params->{notify_url}     = $self->config->{refund_notify_url};
    $params->{refund_date}    = DateTime->now( time_zone => 'Asia/Shanghai' )->strftime('%Y-%m-%d %H:%M:%S');
    $params->{detail_data}    = join( '#', @details_data );
    $params->{batch_num}      = $batch_num;
    $params->{sign}           = $self->make_sign($params);
    return $params;
}

sub verify_notify_sign {
    my $self   = shift;
    my $params = shift;

    my $sign_request = delete $params->{sign};
    my $sign         = $self->make_sign($params);
    return 1 if $sign_request and $sign eq $sign_request;
}

sub verify_notify_id {
    my $self      = shift;
    my $notify_id = shift;
    my $params    = {
        service   => 'notify_verify',
        partner   => $self->config->{seller_id},
        notify_id => $notify_id
    };
    my $content = $self->ua->post( 'https://mapi.alipay.com/gateway.do', form => $params )->res->content->asset->{content};
    return 1 if $content and $content eq 'true';
}

sub make_sign {
    my $self        = shift;
    my $params      = shift || {};
    my $params_sign = {};
    map { $params_sign->{$_} = $params->{$_} if $_ !~ /^sign(_type)?$/ and defined $params->{$_} } keys %$params;
    my $sign_string = join( '&', map { sprintf( '%s=%s', $_, $params_sign->{$_} ) } sort { $a cmp $b } keys %$params_sign ) . $self->config->{sign};
    Encode::_utf8_off($sign_string);
    return md5_hex($sign_string);
}

sub __seconds_to_it_b_pay {
    my $self    = shift;
    my $seconds = shift;
    return unless $seconds and $seconds =~ /^\d+$/;

    $seconds = int $seconds;
    my $day = int( $seconds / 3600 / 24 );
    $seconds -= $day * 3600 * 24;
    if ( $day and not $seconds ) {
        return sprintf( '%dd', $day );
    }

    my $hour = int( $seconds / 3600 );
    $seconds -= $hour * 3600;
    if ( $hour and not $seconds ) {
        return sprintf( '%dh', $day * 24 + $hour );
    }

    my $minute = int( $seconds / 60 );
    $seconds -= $minute * 60;
    $minute += 1 if $seconds > 0;

    return sprintf( '%dm', $day * 24 * 60 + $hour * 60 + $minute );
}

1;
