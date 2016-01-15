#!/usr/bin/perl

#================================================================================
# HEADER, perl stuff
use File::Basename;
use File::Find;
use URI::Escape;
use constant true => 1;
use constant false => 0;


#turns on flushing
$| = 1;

sub usage;
sub upload; sub http; sub httpOk; sub jsonMapExtract;
sub logger; sub logIndent; sub logLevel; sub logDebug; sub logWarn; sub logInfo; sub logError; 

#================================================================================
my $MANIFEST_FILENAME="dfstudio-upload-history.txt";
my $DEFAULT_SETUP = "default";
my $LOG_LEVEL = 1; # 0=all, 5=no messages
my @SKIP_FILENAMES = ( "$MANIFEST_FILENAME", ".DS_Store");
#================================================================================
# This script uploads files to DFStudio.com
# Given an initial directory it uploads the files following this pattern: 
#   [Initial Directory]/[Folder]/[Project]/[Setup]
#
# If the [Project] directory contains files they will be uploaded into the Default Setup.
# This script can be cancelled at any time and will resume where it left off.  
# For projects that a partially uploaded, uploads will place the images into the original project, even if the project has moved in DF Studio.
#

my $argcount = @ARGV;
if ($argcount < 1){ usage(); }

my $INIT_DIR= shift @ARGV;
my $DFSTUDIO_URL = "";
my $USERNAME=""; 
my $ACCOUNT="";
my $PASSWORD="";
my $MODE = "run";  # [ test, reset, run ]

while( $ARGV[0] =~ "^-") {
  my $opt = shift @ARGV;
  if ( $opt =~ /--site/ ) {
    $DFSTUDIO_URL = shift @ARGV;
    if ($DFSTUDIO_URL !~ /^http/){
      $DFSTUDIO_URL = "https://$DFSTUDIO_URL";
    }
  } elsif ( $opt =~ /--login/ ) {
    $USERNAME = shift @ARGV;
  } elsif ( $opt =~ /--account/ ) {
    $ACCOUNT = shift @ARGV;
  } elsif ( $opt =~ /--password/ ) {
    $PASSWORD = uri_escape(shift @ARGV);
  } elsif ( $opt =~ /--reset/ ) {
    $MODE = "reset";
  } elsif ( $opt =~ /--test/ ) {
    $MODE = "test";
  }
}

#================================================================================

if (! $INIT_DIR ) {
  usage();
}
if ($MODE ne "reset"){
  if (!$DFSTUDIO_URL || ! $USERNAME || ! $ACCOUNT || ! $PASSWORD) {
    usage();
  }
}

if ( $MODE eq "reset" ) {
  `find "$INIT_DIR" -type f -name "$MANIFEST_FILENAME" -delete`;
  print "\"$MANIFEST_FILENAME\" files have been removed\n";
  exit 0;
}

# LOOPS OVER DIRECTORY AND FILES
foreach my $folderPath ( glob("'$INIT_DIR/*'") ) {
  if ( -d $folderPath ) {
    my $folderName = basename($folderPath);
    logIndent(0); logInfo("FOLDER:$folderName\n");
    foreach my $projectPath ( glob("'$folderPath/*'") ) {
      if ( -d $projectPath ) {
        my $projectName = basename($projectPath);
        logIndent(1); logInfo("PROJECT:$projectName\n");
        foreach my $projectItem ( glob("'$projectPath/*'")) {
          if ( -f $projectItem ) {
            upload($folderName,$projectName,$DEFAULT_SETUP,$projectItem);
          } elsif ( -d $projectItem ) {
            my $setupName=basename($projectItem);
            logIndent(2); logInfo("  SETUP:$setupName\n");
            foreach my $setupItem (glob("'$projectItem/*'")) {
              if ( -f $setupItem ) {
                upload($folderName,$projectName,$setupName,$setupItem);
              } elsif ( -d $setupItem) { 
                #setupItem is a directory - find any nested files and upload them to this setup, junking intermediate folders
                #http://www.perlmonks.org/?node_id=217166
                find(sub {upload($folderName,$projectName,$setupName,$File::Find::name) if -f}, "$setupItem");
              }
            }
          }
        }
      }
    }
  }
}


#================================================================================
# Subroutines 
sub usage {
  print "Usage: df-uploader.pl BASE_DIRECTORY --site SITE --login LOGIN --account ACCOUNT --password PASSWORD [--test --reset]\n";
  exit 0;
}

my ($SESSION_URL,$HTTP_STATUS,$HTTP_OUTPUT);
sub upload {
  my ($folder, $project, $setup, $file) = @_;
  logIndent(4);
  my $folderUri = uri_escape($folder);
  my $projectUri = uri_escape($project);
  my $setupUri = uri_escape($setup);
  my $filename = basename($file);
  my $filenameUri = uri_escape($filename);
  my $dir = dirname($file);

  # http://www.perlmonks.org/?node_id=2482
  if ( @found = grep { $_ eq $filename } @SKIP_FILENAMES ){
    return 1;
  }
  if ( $MODE eq "test" ) {
    logInfo("UPLOAD($file)\n");
    return 1;
  }
  logInfo("FILE:$file... ");

  # Manifest File
  my $projectId = "";
  my $manifestFile = "$dir/$MANIFEST_FILENAME";
  if ( -f $manifestFile ) {
    if ( `grep -l '$filename' '$manifestFile'` ) {
      logInfo("skipping already done\n",true);
      return 1;
    }
    ($projectId) = `grep -m 1 "ProjectId=" '$manifestFile'` =~ /ProjectId=(.+)\b/;
  } 
  my $attempts = 0;
  while (true) {
    # Sleep Retry Timer
    $attempts++;
    if ( $attempts > 1 ) {
      my $sleepSec = 2*($attempts-1);
      if ( $sleepSec > 120 ) {
        $sleepSec = 120; 
      }
      logInfo(".",true);
      sleep $sleepSec; 
    }
    
    # Session 
    if ( ! $SESSION_URL ) {
      http("POST","$DFSTUDIO_URL/rest/v3/session.json","-d username=$USERNAME -d account=$ACCOUNT -d password=$PASSWORD");
      next if ( ! httpOk() );
      ($SESSION_URL) = $HTTP_OUTPUT =~ /^"(.+)\.json"$/;
      if ( ! $SESSION_URL ) { exit 1; }
    }

    # Project 
    if ( ! $projectId )  {
      http("POST","$SESSION_URL/path/$folderUri/$projectUri","-d rest.syntax=json -d type=project");
      next if ( ! httpOk() );
      ($projectId) = jsonMapExtract("id");
      `echo 'ProjectId=$projectId' >> '$manifestFile'`;
      logDebug("New Project: $project -> $projectId");
    }

    # Image 
    http("POST","$SESSION_URL/path/((project:$projectId))/$filenameUri","-d rest.syntax=json -d setup=$setupUri -d type=image -d action=uploadUrlRequest");
    next if ( ! httpOk() );
    my $uploadUrl = jsonMapExtract("uploadUrl");
    my $uploadType = jsonMapExtract("uploadContentType");
    my $uploadCallback = jsonMapExtract("uploadOnCompleteUrl");

    http("PUT",$uploadUrl,$uploadType,$file);
    next if ( ! httpOk() );
    http("POST",$uploadCallback);
    next if ( ! httpOk() );
    `echo '$filename' >> '$manifestFile'`;
    logInfo("done\n",true);
    return 1;
  }
}

sub http {
  my ($method,$url) = @_;
  my $opts="-X $method";
  if ( @_ == 3 ) {
    my $params=$_[2];
    $opts .= " $params";
  } elsif ( @_ == 4 ) {
    my $contentType = $_[2];
    my $file = $_[3];
    $opts .= " --header \"Content-Type:$contentType\" --data-binary \"\@$file\"";
  }
  #create temp output file
  my $outputFile = ".http-output.$PID.tmp";
  `echo > $outputFile`;
  #execute curl cmd
  my $status=`curl -s -S --retry 5 -w %{http_code} --output $outputFile --stderr $outputFile $opts "$url"`;
  my $output=`cat $outputFile`;
  if ( $status < 200 || $status >= 300 ) {
    logWarn("WARN: curl $opts \"$url\" -> $status -> $output\n");
  } else {
    logDebug("DEBUG: curl $opts \"$url\" -> $status -> $output\n");
  }

  #remove temp output file
  unlink $outputFile;
  #copy local vars into global for simple uses
  ($HTTP_STATUS,$HTTP_OUTPUT)=($status,$output);
  #return local vars
  return ($status,$output);
}

# uses $HTTP_STATUS,$SESSION_URL $RETRIES 
sub httpOk() {
  if  ( $HTTP_STATUS >= 200 && $HTTP_STATUS < 300 ) {
    return true;
  } elsif ( $HTTP_STATUS == 401 ) {
    logError("ERROR: wrong username/account/password\n");
    exit 2;
  } elsif ( $HTTP_STATUS == 408 ) {
    logWarn("WARN: session expired\n");
    $SESSION_URL = "";
    return false;
  }
  return false;
}

sub jsonMapExtract {
  my $input,$key;
  if ( @_ == 1 ) {
    ($input,$key)=($HTTP_OUTPUT,$_[0]);
  } else {
    ($input,$key)= @_;
  }
  if ( $input =~ m/"$key":"([^"]+)"/ ) {
    return $1;
  } else {
    return "";
  }
}

#================================================================================
# LOGGING 
my $LOG_INDENT= 0; # set by the logIndent command
sub logger {
  my ($mssage,$noIndent,$level) =@_;
  my $space = ("  " x $LOG_INDENT);
  if ( $noIndent ) {
    $space = "";
  }
  print ($space.$mssage) if ( $LOG_LEVEL < $level );
}
sub logIndent {
  ($LOG_INDENT)=@_;
}
sub logLevel {
  ($LOG_LEVEL)=@_;
}

sub logDebug {
  logger(@_[0],@_[1],1);
}
sub logInfo {
  logger(@_[0],@_[1],2);
}
sub logWarn {
  logger(@_[0],@_[1],3);
}
sub logError {
  logger(@_[0],@_[1],4);
}
  




