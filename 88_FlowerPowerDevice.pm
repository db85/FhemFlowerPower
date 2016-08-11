package main;

use strict;
use warnings;
use POSIX;
use JSON; 
use HTTP::Date;
use HTTP::Date;

sub FlowerPowerDevice_Initialize($$)
{
  my ($hash) = @_;

  $hash->{DefFn}   = "FlowerPowerDevice_Define";
  $hash->{UndefFn} = "FlowerPowerDevice_Undef";
  $hash->{GetFn}   = "FlowerPowerDevice_Get";
  $hash->{SetFn}   = "FlowerPowerDevice_Set";
  $hash->{AttrList}= $readingFnAttributes;
  $hash->{NotifyFn}= "FlowerPowerDevice_Notify";
}

sub FlowerPowerDevice_RearmTimer($$) {
  my ($hash, $t) = @_;
  InternalTimer($t, "FlowerPowerDevice_UpdateData", $hash, 0) ;
}

sub FlowerPowerDevice_DisarmTimer($) {
  my ($hash)= @_;
  RemoveInternalTimer($hash);
}

sub FlowerPowerDevice_UpdateData($) {
  my ($hash) = @_;

  my $hashApi = $defs{$hash->{API_NAME}};

  FlowerPowerDevice_RearmTimer($hash, gettimeofday()+$hash->{INTERVAL});

  if(!$hashApi) {
    Log3 undef, 1, "FlowerPowerDevice: unknown api module:".$hash->{API_NAME};
    return undef;
  }

  my $json_reading = ".location_".$hash->{LOCATION_IDENTIFIER};
  my $locationJson=$hashApi->{READINGS}{$json_reading}{VAL};

  if($locationJson eq "") {
    return undef;
  }

  my $data = eval { decode_json($locationJson) };

  my $lastLastUpdate = str2time($hash->{READINGS}{"last_sample_utc"}{TIME});
  my $lastDataDate = str2time($data->{"last_sample_utc"});
  if($lastLastUpdate gt $lastDataDate){
    return undef;
  }

  FlowerPowerDevice_ReadLocationData($hash, $data);
}

sub FlowerPowerDevice_Define($$) {
  my ($hash, $def) = @_;

  my @a = split("[ \t][ \t]*", $def);

  return "syntax: define <name> FlowerPowerDevice <api_name> <location_identifier> <interval_in_sec>"
    if(int(@a) < 5 && int(@a) > 5); 

  my $name                  = $a[0];
  my $api_name              = $a[2];
  my $location_identifier   = $a[3];
  my $interval_in_sec       = $a[4];

  $hash->{STATE}                = "Initialized";
  $hash->{LOCATION_IDENTIFIER}	= $location_identifier;
  $hash->{API_NAME}             = $api_name;
  $hash->{INTERVAL}             = $interval_in_sec;

  FlowerPowerDevice_UpdateData($hash) if($init_done);

  return undef;
}

sub FlowerPowerDevice_Undef($$) {
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub FlowerPowerDevice_Get($@) {
  my ($hash, @a) = @_;

  return "argument is missing" if(int(@a) != 2);

  my $reading= $a[1];
  my $value;

  if(defined($hash->{READINGS}{$reading})) {
    $value= $hash->{READINGS}{$reading}{VAL};
  } else {
      my $rt= ""; 
      if(defined($hash->{READINGS})) {
        $rt= join(" ", sort keys %{$hash->{READINGS}});
      }   
      return "Unknown reading $reading, choose one of " . $rt;
  }

  return "$a[0] $reading => $value";
}

sub FlowerPowerDevice_Set($@) {
  return undef;
}

sub FlowerPowerDevice_Notify($$) {
    my ($hash,$dev) = @_;

  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  FlowerPowerDevice_DisarmTimer($hash);
  my $delay= 10+int(rand(20));
  FlowerPowerDevice_RearmTimer($hash, gettimeofday()+$delay) ;
  return undef;
}

sub FlowerPowerDevice_ReadLocationData($$) {
  my ($hash, $location_data) = @_;

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "identifier", $location_data->{"location_identifier"});
  readingsBulkUpdate($hash, "last_processed_upload_timedate_utc", $location_data->{"last_processed_upload_timedate_utc"});
  readingsBulkUpdate($hash, "total_sample_count", $location_data->{"total_sample_count"});
  readingsBulkUpdate($hash, "last_sample_upload", $location_data->{"last_sample_upload"});
  readingsBulkUpdate($hash, "first_sample_utc", $location_data->{"first_sample_utc"});
  readingsBulkUpdate($hash, "last_sample_utc", $location_data->{"last_sample_utc"});
  readingsBulkUpdate($hash, "global_validity_timedate_utc", $location_data->{"global_validity_timedate_utc"});
  readingsBulkUpdate($hash, "sharing_status", $location_data->{"user_sharing"}{"first_all_green"}{"sharing_status"});

  FlowerPowerDevice_ReadLocationSensorData($hash, "air_temperature_", $location_data->{"air_temperature"});
  FlowerPowerDevice_ReadLocationSensorData($hash, "light_", $location_data->{"light"});
  FlowerPowerDevice_ReadLocationSensorData($hash, "soil_moisture_", $location_data->{"soil_moisture"});
  FlowerPowerDevice_ReadLocationSensorData($hash, "fertilizer_", $location_data->{"fertilizer"});
  readingsEndUpdate($hash, 1);
}
sub FlowerPowerDevice_ReadLocationSensorData($$$) {
  my ($hash, $label, $data) = @_;
  
  readingsBulkUpdate($hash, $label."status_key", $data->{"status_key"});
  readingsBulkUpdate($hash, $label."instruction_key", $data->{"instruction_key"});
  readingsBulkUpdate($hash, $label."next_analysis_timedate_utc", $data->{"next_analysis_timedate_utc"});
  readingsBulkUpdate($hash, $label."predicted_action_timedate_utc", $data->{"predicted_action_timedate_utc"});
  readingsBulkUpdate($hash, $label."done_action_timedate_utc", $data->{"done_action_timedate_utc"});
  readingsBulkUpdate($hash, $label."gauge_values_min", $data->{"gauge_values"}{"min_threshold"});
  readingsBulkUpdate($hash, $label."gauge_values_max", $data->{"gauge_values"}{"max_threshold"});
  readingsBulkUpdate($hash, $label."gauge_values_current", $data->{"gauge_values"}{"current_value"});
  }
1;
