#! /usr/bin/perl

use constant DEBUG => 0;
use strict;
use warnings;
use Path::Tiny;
use DBI;
use utf8;
use Data::Dumper;
use JSON;
use Time::Piece;
use Email::Valid;

use atol;

use open qw(:std :utf8);
binmode(STDOUT,':utf8');
binmode(STDIN,':utf8');


do "./config.pl";
use vars qw(%db_conf);
use vars qw(%atol_conf);
use vars qw(%company_conf);
use vars qw(%mailserver_conf);
use vars qw(%patch_conf);

my $atol_token = "-";
my $atol_error = '';
my $atol_message = '';
my $atol_uuid = '';
my $time = Time::Piece->new;
my $unixtime = $time->epoch;
my $unixtime_3dayago = $unixtime - (60*60*24*3);


my $dbh = DBI->connect("DBI:mysql:dbname=$db_conf{db_name}:hostname=$db_conf{db_host}",$db_conf{db_login},$db_conf{db_password}) or die ("db not connect");



##############################################################################################
# 1
# новые платежи прошедшие через нужную систему платежей (method=102) переносим в таблицу чеков для дальнейшей работы с ними
my $sql1 = "SELECT pt.id, pt.account_id, pt.payment_incurrency, pt.payment_enter_date, u.email, u.mobile_telephone
FROM payment_transactions pt
LEFT JOIN users_accounts ua ON (ua.account_id = pt.account_id)
LEFT JOIN users u ON (u.id = ua.uid)
WHERE pt.method = 102
AND pt.id NOT IN (SELECT pt_id FROM rm_atol)
AND pt.payment_enter_date > ($unixtime_3dayago)
ORDER BY pt.id DESC
limit 10
";

my $sth1 = $dbh->prepare($sql1) or die "Couldn't prepare statement: ".$dbh->errstr;
$sth1->execute() or die "Couldn't execute statement: ".$sth1->errstr.print "\n sql1 problem \n";
while ( my @row1 = $sth1->fetchrow_array ) {
	my $payment_id = $row1[0];
	my $account_id = $row1[1];
	my $payment_incurrency = $row1[2];
	my $payment_enter_date = $row1[3];
	my $payer_email = $row1[4];
	my $payer_telephone = $row1[5];
	
	my $sql2 = "INSERT INTO rm_atol
	( pt_id, payer_email, amount, payer_telephone )
	VALUES
	( $payment_id, '$payer_email', $payment_incurrency, '$payer_telephone')
	";
	print "$sql2 \n \n" if DEBUG;

	my $sth2 = $dbh->prepare($sql2);
	$sth2->execute() or die "Couldn't execute statement: ".$sth2->errstr.print "\n  $sql2 \n";
	$sth2->finish;
}
$sth1->finish;
#########################################################################################################
	





##############################################################################################
# 2
# передаем в Атол данные по имеющимся новым платежам
my $sql3 = "SELECT pt_id, payer_email, amount, payer_telephone
FROM rm_atol
WHERE is_send_to_atol = 0
ORDER BY id
limit 10
";
print "$sql3 \n \n" if DEBUG;
my $sth3 = $dbh->prepare($sql3) or die "Couldn't prepare statement: ".$dbh->errstr;
$sth3->execute() or die "Couldn't execute statement: ".$sth3->errstr.print "\n sql3 problem \n";

if($sth3->rows) {
	print "We have data for Atol!\n" if DEBUG;
	
	# получаем у АТОЛ токен для текущего сеанса
	($atol_error, $atol_token, $atol_message) = &get_token( $atol_conf{atol_login}, $atol_conf{atol_password});

	if ( $atol_error == 1 ) {
		print "atol_error $atol_error ERROR CODE $atol_message->{error}->{code}" if DEBUG;
		die "ERROR no token";
	} else {
		print "\n atol_token $atol_token \n" if DEBUG;
	}
}

while ( my @row3 = $sth3->fetchrow_array ) {
	my $payment_id = $row3[0];
	my $payer_email = $row3[1];
	my $amount = $row3[2];
	my $payer_telephone = $row3[3];

	# если формат адреса электропочты плательщика не правильный то сбрасываем адрес его электропочты
	unless( Email::Valid->address($payer_email) ) { $payer_email = ''; }

	# формат номера мобильного телефона плательщика приводим к формату нужному Атол или сбрасываем номер
	$payer_telephone = convert_phonenumber($payer_telephone);

	# если нет валидных координат плательщика то отдаем Атолу noreply адрес организации т.к. Атол не регистрирует документы без данных плательщика
	if ( $payer_email eq '' and $payer_telephone eq '' ) { $payer_email = "$company_conf{company_email_noreply}"; }

	# отправляем в Атол данные для регистрации документа (чека)
	$atol_uuid = &send_check ($atol_token, $payment_id, $payer_email, $payer_telephone, $amount, $atol_conf{atol_group_code}, %company_conf);

	if ( $atol_uuid ne '' ) {
		my $sql4 = "UPDATE rm_atol
		SET is_send_to_atol = 1, atol_uuid = '$atol_uuid'
		WHERE pt_id = $payment_id";
		print "$sql4 \n \n" if DEBUG;
		my $sth4 = $dbh->prepare($sql4);
		$sth4->execute() or die "Couldn't execute statement: ".$sth4->errstr.print "\n  $sql4 \n";
		$sth4->finish;
	} else {
		print "ERROR send $payment_id to Atol \n\n" if DEBUG;
	}

	sleep 1;
}
$sth3->finish;
####################################################################################





##############################################################################################
# 3
# получаем у Атола регистрационные данные ранее отправленных ему документов (чеков)
my $sql5 = "SELECT ra.pt_id, ra.atol_uuid, ra.payer_email, pt.account_id
FROM rm_atol ra
LEFT JOIN payment_transactions pt ON (pt.id = ra.pt_id)
WHERE ra.is_send_to_atol = 1
AND ra.atol_status != 'done'
ORDER BY ra.id
limit 10
";
print "$sql5 \n \n" if DEBUG;
my $sth5 = $dbh->prepare($sql5) or die "Couldn't prepare statement: ".$dbh->errstr;
$sth5->execute() or die "Couldn't execute statement: ".$sth5->errstr.print "\n sql5 problem \n";

if($sth5->rows) {
	print "We wait data from Atol!\n" if DEBUG;
	# получаем у Атол токен для текущего сеанса
	($atol_error, $atol_token, $atol_message) = &get_token( $atol_conf{atol_login}, $atol_conf{atol_password});
	if ( $atol_error == 1 ) {
		print "atol_error $atol_error ERROR CODE $atol_message->{error}->{code}";
		die "ERROR no token";
	} else {
		print "\n atol_token $atol_token \n" if DEBUG;
	}

}


while ( my @row5 = $sth5->fetchrow_array ) {
	my $payment_id = $row5[0];
	my $atol_uuid = $row5[1];
	my $payer_email = $row5[2];
	my $account_id = $row5[3];

	print "get from Atol payment_id $payment_id \n" if DEBUG;
	# запрашиваем у Атол данные по ранее отправленным и зарегистрированным им документам (чекам)
	my ($error_get, $message) = &get_check_status($atol_token, $atol_uuid, $atol_conf{atol_group_code});

	if ( $error_get == 0 ) {
		my $mreceipt_datetime = Time::Piece->strptime($message->{payload}->{receipt_datetime}, "%d.%m.%Y %H:%M:%S");
		$mreceipt_datetime = $mreceipt_datetime->strftime("%Y-%m-%d %H:%M:%S");
		my $message_json = encode_json($message);

		my $sql6 = "UPDATE rm_atol
		SET atol_status = '$message->{status}', 
		atol_receipt_datetime = '$mreceipt_datetime',
		kkt_device_code = '$message->{device_code}',
		ofd_receipt_url = '$message->{payload}->{ofd_receipt_url}', 
		check_info = '$message_json'
		WHERE atol_uuid = '$atol_uuid'";
		print "$sql6 \n \n" if DEBUG;
		my $sth6 = $dbh->prepare($sql6);
		$sth6->execute() or die "Couldn't execute statement: ".$sth6->errstr.print "\n  $sql6 \n";
		$sth6->finish;
		
		# если у нас есть валидный email-адрес плательщика, то готовим и отправляем на него письмо с данными чека
		if ( Email::Valid->address($payer_email) ) {
			# готовим текст письма для плательщика
			my $text_for_email = &make_text_for_email($message, $account_id, $payer_email);
		
			# готовим и создаем картинку qrcod для письма плательщику
			my $qrcode_text = "t=$mreceipt_datetime&s=$message->{payload}->{total}&fn=$message->{payload}->{fn_number}&i=$message->{payload}->{fiscal_document_number}&fp=$message->{payload}->{fiscal_document_attribute}&n=1";
			&create_qrcode( $payment_id, $qrcode_text );
		
			&send_check_to_email ($payer_email, $text_for_email, $payment_id);
		}


	} else {
		my $sql6 = "UPDATE rm_atol
		SET atol_status = '$message->{status}'
		WHERE atol_uuid = '$atol_uuid'";
		print "$sql6 \n \n" if DEBUG;
		my $sth6 = $dbh->prepare($sql6);
		$sth6->execute() or die "Couldn't execute statement: ".$sth6->errstr.print "\n  $sql6 \n";
		$sth6->finish;
		
	}

	sleep 1;
}
$sth5->finish;
####################################################################################



$dbh->disconnect;

# the END







sub convert_phonenumber {
	my ( $payer_telephone ) = @_;
	
	$payer_telephone =~ s/[^0-9]//g;
	if (  length($payer_telephone) == 11 and substr($payer_telephone, 0 ,1) == 8) {
		$payer_telephone = "+7".substr($payer_telephone, 1 ,10);
	} elsif  ( length($payer_telephone) == 10 and substr($payer_telephone, 0 ,1) == 9) {
		$payer_telephone = "+7".$payer_telephone;
	} else {
		$payer_telephone = '';
	}
	return $payer_telephone;
}


sub create_qrcode {
     my ( $qrcode_id, $qrcode_text ) = @_;
    use Imager::QRCode;
    my $qrcode = Imager::QRCode->new(
    size          => 2,
    margin        => 2,
    version       => 1,
    level         => 'M',
    casesensitive => 1,
    lightcolor    => Imager::Color->new(255, 255, 255),
    darkcolor     => Imager::Color->new(0, 0, 0),
    );
    my $img = $qrcode->plot($qrcode_text);
    $img->write(file => "$patch_conf{patch_to_qrcode}qrcode-$qrcode_id.bmp")
         or die "Failed to write: " . $img->errstr;

	return 1;
}




sub make_text_for_email {
	my ($message, $account_id, $payer_email) = @_;
	my $font1 = qq{<font face="Arial, Helvetica, sans-serif" size="1">};
    my $font2 = qq{<font face="Arial, Helvetica, sans-serif" size="2">};
    my $font3 = qq{<font face="Arial, Helvetica, sans-serif" size="3">};
	my $font4 = qq{<font face="Arial, Helvetica, sans-serif" size="4">};
	my $color1 = "#1E7F9F";
	my $color2 = "#CCEBFF";

	my $text_email = '';
	$text_email = qq{
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <title>Demystifying Email Design</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    </head>
    <body>
    <table width="100%" border="2" bordercolor="$color1" valign="top" align="center" cellpadding="10" cellspacing="0" bgcolor="$color2">
    <tr valign="top"><td align="center" valign="top" width="70%">
    <font face="Arial, Helvetica, sans-serif" size="2">
    <br>$company_conf{company_name}
    <br>ИНН $company_conf{company_inn}
    <br>$company_conf{company_address}
    </font>
    $font4<br><br>КАССОВЫЙ ЧЕК. Приход.</font>
    <br><br>
	<table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 СМЕНА $message->{payload}->{shift_number}</td>
    <td align="right" valign="top">$font2 АВТ $message->{device_code}</td></tr>
    <tr valign="top">
    <td align="left" valign="top" width="50%">$font2 Чек № $message->{payload}->{fiscal_document_number}</td>
    <td align="right" valign="top">$font2 ККТ ДЛЯ ИНТЕРНЕТ</td></tr>
    <tr valign="top">
    <td align="left" valign="top" width="50%">$font2 $message->{payload}->{receipt_datetime}</td><td></td></tr>
    </table><br>
	
    <hr align="center" width="98%" size="5" color="$color1"/><Br>
	
	<table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="center" valign="top" width="10%">$font2 №</td>
    <td align="center" valign="top" width="40%">$font2 Наименование</td>
    <td align="center" valign="top" width="20%">$font2 Цена за единицу</td>
    <td align="center" valign="top" width="10%">$font2 Кол-во</td>
    <td align="center" valign="top" width="20%">$font2 Сумма (руб.)</td>
    </tr>
    <tr valign="top" >
    <td align="center" valign="top" width="10%">$font2 1</td>
    <td align="center" valign="top" width="40%">$font2 услуги телекоммуникационные проводные<br>Лицевыой счет $account_id<Br>Полный расчет
	</td>
    <td align="center" valign="top" width="20%">$font2 $message->{payload}->{total}</td>
    <td align="center" valign="top" width="10%">$font2 1</td>
    <td align="center" valign="top" width="20%">$font2 $message->{payload}->{total}</td>
    </table>
    <br>
    <table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 НДС</td>
    <td align="right" valign="top">$font2 без НДС</td></tr>
    </table>
    <br>

    <table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font4 ИТОГО:</td>
    <td align="right" valign="top">$font4 $message->{payload}->{total}</td></tr>
    </table>
    <table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 БЕЗНАЛИЧНЫМИ</td>
    <td align="right" valign="top">$font2 $message->{payload}->{total}</td></tr>
    </table>
    <br><hr align="center" width="98%" size="5" color="$color1"/><Br>
    $font3          ККТ $message->{payload}->{ecr_registration_number}<Br>ФН $message->{payload}->{fn_number}<Br>ФП $message->{payload}->{fiscal_document_attribute}
    <br><br>
    <img src="cid:qrcode-$message->{external_id}.bmp">
    <br><br><hr align="center" width="98%" size="5" color="$color1"/><Br>
	<table width="100%" border="0" valign="top" align="center" cellpadding="4" cellspacing="0">
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 Налогообложение</td>
    <td align="right" valign="top">$font2 УСН доходы минус расходы</td></tr>
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 Место расчетов</td>
    <td align="right" valign="top">$font2 $company_conf{company_payment_address}</td></tr>
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 Эл. адрес покупателя</td>
    <td align="right" valign="top">$font2 $payer_email</td></tr>
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 Эд. адрес отправителя</td>
    <td align="right" valign="top">$font2 $company_conf{company_email_official}</td></tr>
    <tr valign="top" >
    <td align="left" valign="top" width="50%">$font2 Сайт ФНС</td>
    <td align="right" valign="top">$font2 https://www.nalog.ru</td></tr>
    </table>
    <br>
    $font1 Адрес ККТ: 109316, Регион 77, Москва, Волгоградский проспект, дом  42, корпус 9
	</td></tr></table>
    </body>
    </html>
    };
	return $text_email;
}




sub send_check_to_email {
    my ($to_email, $text_for_email, $qrcode_id ) = @_;

	use MIME::Lite;
	use Net::SMTPS;
	use Net::SMTP;

    my $mail = MIME::Lite->new(
            From    => $mailserver_conf{mailserver_emailfrom},
            To      => $to_email,
            Subject => Encode::encode_utf8($mailserver_conf{mailserver_emailsubject}),
            Type    => 'multipart/mixed'
    );
    $mail->attach(
            Type => 'text/html; charset=utf-8',
            Data     => Encode::encode_utf8($text_for_email)
    );
    $mail->attach(
            Type     => 'image/bmp',
            Id   => "qrcode-$qrcode_id.bmp",
            Path     => "$patch_conf{patch_to_qrcode}qrcode-$qrcode_id.bmp",
    );

    my $smtps = Net::SMTPS->new($mailserver_conf{mailserver_host}, Port => 25,  doSSL => 'login', Debug=>0);
	$smtps ->auth($mailserver_conf{mailserver_username}, $mailserver_conf{mailserver_userpassword});
    $smtps ->mail($mailserver_conf{mailserver_emailfrom});
    $smtps->to($to_email);
    $smtps->data();
    $smtps->datasend( $mail->as_string() );
    $smtps->dataend();
    $smtps->quit;

	return 1;
}

