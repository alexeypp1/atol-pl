
package atol;

use constant DEBUG => 0;
use Exporter 'import';
use HTTP::Request;
use LWP::UserAgent;
use JSON;
use Encode qw(encode decode);
use Data::Dumper;
use Time::Piece;
use utf8;


#	v 1.00
#	Неофициальный Perl Modile для работы с онлайн-кассами Атол (www.atol.ru) по API v 4.11
#
#	Модуль регистрирует в ККТ документы простейшего вида способом расчета 'Полный расчет', с количество=1 единица измерения='шт.'
#	с параметрами для организации оказывающей услуги и не являющейся плательщиком НДС
#
#	Поддерживаемые заросы:
#	get_token - получение авторизационного токена
#	send_check - регистрация документа в ККТ
#	get_check_status - получение результата обработки документа
#

my $items_payment_method = "full_payment"; # признак способа расчета 'Полный расчет'
my $items_payment_object = "service"; # признак предмета расчета 'услуга'
my $items_name = 'услуги телекоммуникационные проводные';

my $atol_url = "https://online.atol.ru/possystem/v4";
my $atol_uuid = '';


our @EXPORT=qw(get_token send_check get_check_status);


sub get_token {
    my ( $atol_login, $atol_password) = @_;
    my $atol_token = "";
	my $atol_error = 0;
	my $atol_message = "";
	
    my $json = "{
        \"login\": \"$atol_login\",
        \"pass\": \"$atol_password\"
    }";
	print "$json  \n" if DEBUG;
	
    my $req = HTTP::Request->new( 'POST', "$atol_url/getToken" );
    $req->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $req->content( $json );

    my $lwp = LWP::UserAgent->new;
    my $res = $lwp->request( $req );
    my $atol_message = $res->decoded_content;
    $atol_message = decode_json($atol_message);

    if ( !defined($atol_message->{error}) ) {
        $atol_token = $atol_message->{token};
        return ($atol_error, $atol_token, $atol_message);
    } else {
		$atol_error = 1;
        print "ERROR CODE $atol_message->{error}->{code}\n" if DEBUG;
        print "$atol_message->{error}->{text}\n" if DEBUG;
        return ($atol_error, $atol_token, $atol_message);
    }
}



sub send_check {
    my ( $atol_token, $payment_id, $payer_email, $payer_telephone, $amount, $atol_group_code, %company_conf ) = @_;

	my $time = Time::Piece->new;
	my $check_time = $time->strftime('%d.%m.%y %H:%M:%S');
	my $operation =  'sell';

    my $json = qq{{
        "external_id":"$payment_id",
        "receipt":{
            "client":{
                "email":"$payer_email",
                "phone":"$payer_telephone"
            },
            "company":{
                "email":"$company_conf{company_email}",
                "sno":"$company_conf{company_sno}",
                "inn":"$company_conf{company_inn}",
                "payment_address":"$company_conf{company_payment_address}"
            },
        "items":[{
            "name":"$items_name",
            "price":$amount,
            "quantity":1,
            "sum":$amount,
            "measurement_unit":"шт.",
            "payment_method":"$items_payment_method",
            "payment_object":"$items_payment_object",
            "vat":{
                "type":"none"}}],
        "payments":[{
            "type":1,
            "sum":$amount}],
            "vats":[{
                "type":"none",
                "sum":0}],
        "total":$amount
        },
        "service":{
            "callback_url":"$company_conf{company_callback_url}"},
        "timestamp":"$check_time"
    }};
	print "\n----------------- \n" if DEBUG;
	print Dumper $json if DEBUG;
	print "\n----------------- \n" if DEBUG;
	print "$atol_url/$atol_group_code/$operation \n atol_token $atol_token \n" if DEBUG;

	my $req = HTTP::Request->new( POST => "$atol_url/$atol_group_code/$operation" );
	$req->header( 'Content-Type' => 'application/json; charset=utf-8', 'Token' => "$atol_token" );
	$req->content(encode('UTF-8',$json));
	my $ua = LWP::UserAgent->new;
	my $res = $ua->request( $req );

    my $message = $res->decoded_content;
    $message = decode_json($message);

	print "\n----------------\n"  if DEBUG;
	print Dumper $message if DEBUG;
	print "\n----------------\n"  if DEBUG;

    if ( !defined($message->{error}) ) {
        $atol_uuid = $message->{uuid};
		print "\natol_uuid $atol_uuid \n" if DEBUG;
        return $atol_uuid;
    } else {
        print "ERROR CODE $message->{error}->{code}\n" if DEBUG;
        print "$message->{error}->{text}\n" if DEBUG;
        return $atol_uuid;
    }
}



sub get_check_status {
    my ( $atol_token, $atol_uuid, $atol_group_code ) = @_;
	print "$atol_url/$atol_group_code/report/$atol_uuid?token=$atol_token \n"  if DEBUG;

    my $req = HTTP::Request->new( 'GET', "$atol_url/$atol_group_code/report/$atol_uuid?token=$atol_token");

    my $lwp = LWP::UserAgent->new;
    my $res = $lwp->request( $req );
    my $message = $res->decoded_content;
    $message = decode_json($message);
	
	print "\n----------------\n"  if DEBUG;
	print Dumper $message if DEBUG;
	print "\n----------------\n"  if DEBUG;	

	if ( !defined($message->{error}) ) {
		return (0, $message);
	} else {
		return (1, $message);
	}
}

1;