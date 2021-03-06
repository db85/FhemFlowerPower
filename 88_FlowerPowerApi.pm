package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use POSIX;
use HTTP::Date;
use Encode qw(encode decode);

use constant AUTH_URL => "https://api-flower-power-pot.parrot.com/user/v1/authenticate?grant_type=password&username=%s&password=%s&client_id=%s&client_secret=%s";
use constant PROFILE_URL => "https://api-flower-power-pot.parrot.com/user/v4/profile";
use constant GARDEN_LOCATION_STATUS_URL => "https://api-flower-power-pot.parrot.com/garden/v1/status";
use constant SYNC_DATA_URL => "https://api-flower-power-pot.parrot.com/garden/v2/configuration";


sub FlowerPowerApi_Initialize($$)
{
    my ($hash) = @_;

    $hash->{DefFn} = "FlowerPowerApi_Define";
    $hash->{UndefFn} = "FlowerPowerApi_Undef";
    $hash->{GetFn} = "FlowerPowerApi_Get";
    $hash->{SetFn} = "FlowerPowerApi_Set";
    $hash->{AttrList} = $readingFnAttributes;
    $hash->{NotifyFn} = "FlowerPowerApi_Notify";
}

sub FlowerPowerApi_Define($$) {
    my ($hash, $def) = @_;

    my @a = split("[ \t][ \t]*", $def);

    return "syntax: define <name> FlowerPowerApi <username> <password> <client_id> <client_secret> <update_intervall_in_sec>"
        if (int(@a) < 7 && int(@a) > 7);

    my $name = $a[0];
    my $username = $a[2];
    my $password = $a[3];
    my $client_id = $a[4];
    my $client_secret = $a[5];
    my $interval_in_sec = $a[6];

    #INTERNALS
    $hash->{STATE} = "Initialized";
    $hash->{USERNAME} = $username;
    $hash->{PASSWORD} = $password;
    $hash->{CLIENT_ID} = $client_id;
    $hash->{CLIENT_SECRET} = $client_secret;
    $hash->{INTERVAL} = $interval_in_sec;

    FlowerPowerApi_UpdateData($hash) if ($init_done);

    return undef;
}

sub FlowerPowerApi_Undef($$) {
    my ($hash, $arg) = @_;

    RemoveInternalTimer($hash);
    return undef;
}

sub FlowerPowerApi_Get($@) {
    my ($hash, @a) = @_;

    return "argument is missing" if (int(@a) != 2);

    my $reading = $a[1];
    my $value;

    if (defined($hash->{READINGS}{$reading})) {
        $value = $hash->{READINGS}{$reading}{VAL};
    } else {
        my $rt = "";
        if (defined($hash->{READINGS})) {
            $rt = join(" ", sort keys %{$hash->{READINGS}});
        }
        return "Unknown reading $reading, choose one of ".$rt;
    }

    return "$a[0] $reading => $value";
}

sub FlowerPowerApi_Set($@) {
    my ($hash, @a) = @_;

    my $cmd = $a[1];

    # usage check
    if ((@a == 2) && ($a[1] eq "update")) {
        FlowerPowerApi_DisarmTimer($hash);
        FlowerPowerApi_UpdateData($hash);
        return undef;
    } else {
        return "Unknown argument $cmd, choose one of update";
    }
}

sub FlowerPowerApi_Notify($$) {
    my ($hash, $dev) = @_;

    return if ($dev->{NAME} ne "global");
    return if (!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

    FlowerPowerApi_DisarmTimer($hash);
    my $delay = 10 + int(rand(20));
    FlowerPowerApi_RearmTimer($hash, gettimeofday() + $delay);
    return undef;
}

sub FlowerPowerApi_RearmTimer($$) {
    my ($hash, $t) = @_;
    InternalTimer($t, "FlowerPowerApi_UpdateData", $hash, 0);
}

sub FlowerPowerApi_DisarmTimer($) {
    my ($hash) = @_;
    RemoveInternalTimer($hash);
}

sub FlowerPowerApi_UpdateData($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if (FlowerPowerApi_IsTokenValid($hash)) {
        FlowerPowerApi_FetchProfile($hash);
        FlowerPowerApi_FetchGardenLocationStatus($hash);
        FlowerPowerApi_RearmTimer($hash, gettimeofday() + $hash->{INTERVAL});
    } else {
        FlowerPowerApi_FetchAuth($hash);
    }
    return 1;
}

sub FlowerPowerApi_IsTokenValid($) {
    my ($hash) = @_;
    my $expire = $hash->{READINGS}{"expires_at"}{VAL};

    if ($expire ne "" && $expire > time()) {
        return 1;
    }
    return 0;
}

sub FlowerPowerApi_FetchAuth($) {
    my ($hash) = @_;
    Log3 undef, 1, "fetch auth";
    my %args = (
        grant_type   => "password",
        username     => $hash->{USERNAME},
        password     => $hash->{PASSWORD},
        client_id    => $hash->{CLIENT_ID},
        lient_secret => $hash->{CLIENT_SECRET},
        hash         => $hash
    );

    my $url = sprintf(AUTH_URL, $hash->{USERNAME}, $hash->{PASSWORD}, $hash->{CLIENT_ID}, $hash->{CLIENT_SECRET});

    Log3 undef, 1, "FlowerPowerApi: fetch auth with url (".$url.")";

    HttpUtils_NonblockingGet({
            url          => $url,
                timeout  => 15,
                argsRef  => \%args,
                callback => \&FlowerPowerApi_FetchAuthFinished,
        });

    return undef;
}


sub FlowerPowerApi_FetchAuthFinished($$$) {
    my ($paramRef, $err, $response) = @_;
    my $argsRef = $paramRef->{argsRef};

    my $hash = $argsRef->{hash};

    if ($err) {
        Log3 undef, 1, "FlowerPowerApi: fetch auth failed with $err";
        FlowerPowerApi_RearmTimer($hash, 60);
    } else {
        my $data = eval { decode_json($response) };

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "access_token", $data->{"access_token"});
        readingsBulkUpdate($hash, "expires_at", time() + $data->{"expires_in"} );
        readingsBulkUpdate($hash, "refresh_token", $data->{"refresh_token"} );
        readingsEndUpdate($hash, 1);

        if (FlowerPowerApi_IsTokenValid($hash)) {
            FlowerPowerApi_UpdateData($hash);
        } else {
            FlowerPowerApi_RearmTimer($hash, 60);
        }
    }
}

sub FlowerPowerApi_FetchProfile($) {
    my ($hash) = @_;

    my $header = "Authorization: Bearer ".$hash->{READINGS}{"access_token"}{VAL};

    HttpUtils_NonblockingGet({
            url          => PROFILE_URL,
                timeout  => 15,
                hash     => $hash,
                header   => $header,
                callback => \&FlowerPowerApi_FetchProfileFinished,
        });

    return undef;

}

sub FlowerPowerApi_FetchProfileFinished($$$) {
    my ($paramRef, $err, $response) = @_;
    my $hash = $paramRef->{hash};

    if ($err) {
        Log3 undef, 1, "FlowerPowerApi: fetch profile failed with $err";
    } else {
        my $data = eval { decode_json($response) };

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "email", $data->{"user_profile"}{"email"});
        readingsBulkUpdate($hash, "dob", $data->{"user_profile"}{"dob"});
        readingsBulkUpdate($hash, "pictures_public", $data->{"user_profile"}{"pictures_public"} );
        readingsBulkUpdate($hash, "use_fahrenheit", $data->{"user_profile"}{"use_fahrenheit"});
        readingsBulkUpdate($hash, "use_feet_inches", $data->{"user_profile"}{"use_feet_inches"});
        readingsBulkUpdate($hash, "username", $data->{"user_profile"}{"username"});
        readingsBulkUpdate($hash, "ip_address_on_create", $data->{"user_profile"}{"ip_address_on_create"});
        readingsBulkUpdate($hash, "notification_curfew_start", $data->{"user_profile"}{"notification_curfew_start"});
        readingsBulkUpdate($hash, "notification_curfew_end", $data->{"user_profile"}{"notification_curfew_end"});
        readingsBulkUpdate($hash, "language_iso639", $data->{"user_profile"}{"language_iso639"});
        readingsBulkUpdate($hash, "tmz_offset", $data->{"user_profile"}{"tmz_offset"});
        readingsBulkUpdate($hash, "user_config_version", $data->{"user_config_version"});
        readingsBulkUpdate($hash, "server_identifier", $data->{"server_identifier"});
        readingsEndUpdate($hash, 1);
    }
}

sub FlowerPowerApi_FetchGardenLocationStatus($) {
    my ($hash) = @_;

    my $header = "Authorization: Bearer ".$hash->{READINGS}{"access_token"}{VAL};

    HttpUtils_NonblockingGet({
            url          => GARDEN_LOCATION_STATUS_URL,
                timeout  => 15,
                hash     => $hash,
                header   => $header,
                callback => \&FlowerPowerApi_FetchGardenLocationStatusFinished,
        });

    return undef;
}

sub FlowerPowerApi_FetchGardenLocationStatusFinished($$$) {
    my ($paramRef, $err, $response) = @_;
    my $hash = $paramRef->{hash};

    if ($err) {
        Log3 undef, 1, "FlowerPowerApi: fetch garden location status failed with $err";
    } else {
        my $data = eval { decode_json($response) };

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "garden_status_version", $data->{"garden_status_version"});
        readingsBulkUpdate($hash, "user_config_version", $data->{"user_config_version"});

        my $locations = $data->{"locations"};
        my $i = 0;
        foreach my $location (@{$locations}) {
            #hidden json for device
            my $labelJson = ".location_".$location->{"location_identifier"};
            readingsBulkUpdate($hash, $labelJson, encode_json($location));
            $i++;
        }
        readingsBulkUpdate($hash, "location_count", $i);
        readingsEndUpdate($hash, 1);

        FlowerPowerApi_FetchSyncData($hash);
    }

    FlowerPowerApi_UpdateState($hash);
}

sub FlowerPowerApi_UpdateState($) {
    my ($hash) = @_;

    my $server_identifier = $hash->{READINGS}{"server_identifier"}{VAL};
    my $location_count = $hash->{READINGS}{"location_count"}{VAL};

    $hash->{STATE} = "$server_identifier / $location_count";
}

sub FlowerPowerApi_FetchSyncData($) {
    my ($hash) = @_;

    my $header = "Authorization: Bearer ".$hash->{READINGS}{"access_token"}{VAL};

    HttpUtils_NonblockingGet({
            url          => SYNC_DATA_URL,
                timeout  => 15,
                hash     => $hash,
                header   => $header,
                callback => \&FlowerPowerApi_SyncDataFinished,
        });

    return undef;
}

sub FlowerPowerApi_SyncDataFinished($$$) {
    my ($paramRef, $err, $response) = @_;
    my $hash = $paramRef->{hash};

    if ($err) {
        Log3 undef, 1, "FlowerPowerApi: fetch sync data failed with $err";
    } else {
        my $data = eval { JSON->new->utf8( 0 )->decode( encode('utf-8', $response) )};
        readingsBeginUpdate($hash);
        FlowerPowerApi_SyncData_LocationData($hash, $data );
        readingsEndUpdate($hash, 1);
    }
}

sub FlowerPowerApi_SyncData_SensorData($$$$) {
    my ($hash, $label, $location_identifier, $sensor) = @_;

    readingsBulkUpdate($hash, $label."location_identifier", $location_identifier);
    readingsBulkUpdate($hash, $label."firmware_version", $sensor->{"firmware_version"});
    readingsBulkUpdate($hash, $label."nickname", $sensor->{"nickname"});
    readingsBulkUpdate($hash, $label."color", $sensor->{"color"});
    readingsBulkUpdate($hash, $label."system_id", $sensor->{"system_id"});
    readingsBulkUpdate($hash, $label."sensor_identifier", $sensor->{"sensor_identifier"});
    readingsBulkUpdate($hash, $label."hardware_revision", $sensor->{"hardware_revision"});
    readingsBulkUpdate($hash, $label."calibration_data", $sensor->{"calibration_data"});
    readingsBulkUpdate($hash, $label."sensor_type", $sensor->{"sensor_type"});
    readingsBulkUpdate($hash, $label."nickname", $sensor->{"nickname"});
    readingsBulkUpdate($hash, $label."assignment_datetime_utc", $sensor->{"assignment_datetime_utc"});
}

sub FlowerPowerApi_SyncData_LocationData($$) {
    my ($hash, $data) = @_;

    my $locations = $data->{"locations"};
    my $i = 0;
    foreach my $location (@{$locations}) {
        my $label = "sensor_".$i."_";
        FlowerPowerApi_SyncData_SensorData($hash, $label, $location->{"location_identifier"}, $location->{"sensor"} );
        readingsBulkUpdate($hash, $label."plant_nickname", $location->{"plant_nickname"});
        $i++;
    }

}

sub FlowerPowerApi_Begins_With {
    return substr($_[0], 0, length($_[1])) eq $_[1];
}
sub FlowerPowerApi_Ends_With {
    return substr($_[0], length($_[0]) - length($_[1]), length($_[1])) eq $_[1];
}
1;
