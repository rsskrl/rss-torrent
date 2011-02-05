#!/usr/bin/perl
my ($torrent_save_dir, $history_file, $download_filters_file);
my ($inform_filters_file, $inform_command, $bithdtv_passkey);
my ($proxy, $find_alternative_torrent);

#############################################################################
# 
# pass url or local path to the torrent rss feed. 
#
# !!!!!!!!! run --help for more info !!!!!!!!!!!!
#
#############################################################################
# main settings which must be set here in the script or on the command line

# dir to save downloaded torrent files (client import dir)
$torrent_save_dir = '/home/torrents/queue';

# file for saving history of downloaded torrents.
# this is primarly needed to avoid downloading same things more than once 
$history_file = '/home/torrents/rss.history';

#############################################################################
# files which contain filters. every line is a filter. your can use regexp, & 
# regexp are recommended. it matches from the beginnging of the torrent title.
# you can pass filter as a parameter too like this:
# "-d 'MyShow.S0[1-9]E[0-9][0-9]'" to match every season/episode of MyShow
# you can pass multiple -d matches on the command line

# download filters: matched will be downloaded
$download_filters_file = '/home/torrents/rss.download_filters';

# inform filter: runs $inform_command if matched. it sends push notification
# on my iphone by using prowl (http://prowl.weks.net/) when sth was found.
# matches from inform_filters_file are not being downloaded
# vars which can be replaced in $inform_command: 
# %TITLE% = matched title of the torrent
# %FORMATTED_TITLE = formatted (nice) matched title
$inform_filters_file = '/home/torrents/rss.inform_filters';
#$inform_command = 'prowl.pl -event="rss matched" -notification="%FORMATTED_TITLE%"';

#############################################################################
# some additional settings

# bit-hdtv passkey for repairing tracker link in torrents. bit-hdtv needs
# this because its rss feed is fuc*ed up & this script repairs it
$bithdtv_passkey = '';

# proxy:port for rss & torrent download (I use tor 'http://127.0.0.1:8118')
$proxy = '';

# set to 1 to try to find better alternative torrent in the current feed.
# it works only for isohunt at the moment. 
$find_alternative_torrent = 0;

#############################################################################
# change whatever you wish if you know what are you doing

use warnings;
use strict;
use XML::Simple;
use LWP::UserAgent;
use Getopt::Long;
use Data::Dumper;

my (@download_filters, @inform_filters, $dry_run, $help);
GetOptions(
	'd|download-filter:s'		=> \@download_filters,
	'i|inform-filter:s'		=> \@inform_filters,
	'X|download-filters-file:s'	=> \$download_filters_file,
	'Y|inform-filters-file:s'	=> \$inform_filters_file,
	'h|history-file:s'		=> \$history_file,
	't|torrent-save-dir:s'		=> \$torrent_save_dir,
	'inform-command:s'		=> \$inform_command,
	'proxy:s'			=> \$proxy,
	'find-alternative-torrent!'	=> \$find_alternative_torrent,
	'bithdtv-passkey:s'		=> \$bithdtv_passkey,
	'dry-run'			=> \$dry_run,
	'h|help'			=> \$help
);


if ($help) {
	print "RSS parser, optimized for feeds of torrent trackers.\n";
	print "Syntax: ".$0." [OPTION]... [URL|PATH]\n\n";
	print "Options:\n";
	print " -d,   --download-filter=FILTER           search terms or regexp. multiple usage possible (-d FILTER -d FILTER).\n";
	print "                                          it matches from the beginning of the title, case insensitive\n";
	print " -X,   --download-filters-file=FILE       file containing search terms/regexp (one per line)\n\n";

	print " -i,   --inform-filter=FILTER             search terms or regexp. multiple usage possible (-i FILTER -i FILTER).\n";
	print "                                          it matches from the beginning of the title, case insensitive\n";
	print " -Y,   --inform-filters-file=FILE         file containing search terms/regexp (one per line)\n";
	print "       --inform-command=COMMAND           calls it when inform filter was matched. %TITLE% in COMMAND is replaced with\n";
	print "                                          formatted torrent title\n\n";

	print " -t,   --torrent-save-dir=DIR             where to save downloaded torrents\n";
	print " -h,   --history-file=FILTER              file for saving names of downloaded torrents to avoid downloading files twice\n";
	print "       --proxy=PROXY[:PORT]               proxy for downloading torrents\n";
	print "       --dry-run                          runs script without downloading torrents or saving in history\n\n";
	print "Site specific options:\n";
	print "       --find-alternative-torrent         [isohunt] search rss for the same torrents in better quality and more peers\n";
	print "                                          instead of downloading the first torrent found\n";
	print "       --bithdtv-passkey=PASSKEY          [bit-hdtv] your bit-hdtv passkey, used to repair torrents from bit-hdtv feed\n";
	print " -h,   --help                             show this help\n\n";
	exit;
}

die('No feed url/file passed.') if $#ARGV < 0;
my $file = join '', @ARGV;

if ($file =~/^https?:\/\//i) {
	my $req = LWP::UserAgent->new();
        $req->proxy('http', $proxy) if $proxy ; 
	$req->timeout(30);
	$req->show_progress(1);
	print "\n\n";
	my $reqresponse = $req->get($file);
	die('Could not open RSS feed over HTTP') if ($reqresponse->is_error);
	$file = $reqresponse->content;
} else {
	die('Could not find local RSS feed') if ! -e $file;
	open FILE, $file;
	$file = join "", <FILE>;
	close FILE;
}


# remove description because of possible special chars
#$file =~s/<description>.*?<\/description>/<description><\/description>/gs;
$file =~s/&(?!amp;)/&amp;/gi;

# read rss file
my $xml = eval { XMLin($file) };
die('Invalid XML in RSS. Error: '.$@) if ($@);
my @torrents = @{$xml->{'channel'}->{'item'}};
die('No torrents in XML found') if $#torrents < 0;

# get filters from files
push @download_filters, read_file($download_filters_file) if $download_filters_file; 
push @inform_filters, read_file($inform_filters_file) if $inform_filters_file;

# one filter has to exist 
die('No filters found') if ($#download_filters < 0 && $#inform_filters < 0); 

# join filters to '(filter1|filter2|...)'
my $download_filters = '('.(join '|', @download_filters).')' if $#download_filters >= 0;
my $inform_filters = '('.(join '|', @inform_filters).')' if $#inform_filters >= 0;

# check save dir for existance
die('Dir for saving torrents does not exist.') if ! -d $torrent_save_dir;

# get history
my @history = read_file($history_file);


print "------------------------\n".localtime();

foreach (@torrents) {
	my %torrent = %{$_};

	print "\nChecking: ".$torrent{'title'}."\n    ";

	my $mtype = 1;
	# match filters
	if ($inform_filters && $torrent{'title'} =~m/^$inform_filters/i) {
		$mtype = 1;
	} elsif ($download_filters && $torrent{'title'} =~m/^$download_filters/i) {
		$mtype = 2; 
	} else {
		print "Not matched\n";
		next;
	}

	print "Matched\n    ";
	my $matchunlc = $1;

	# check history
	my $match = lc($1);
	$match =~s/(\s{1,})/\./g;
	if (grep { $match eq $_ } @history) {
		print "Found in history\n";
		next;
	}

	# what to do if @inform_filters matched?
	if ($mtype == 1 && $inform_command) {
		my $custom_inform_command = $inform_command;
		if ($inform_command =~ /%((FORMATTED_)?TITLE)%/) {
			my $title_formated = format_title($match);
			$title_formated =~s/\"/\\"/g;
			$custom_inform_command =~ s/%FORMATTED_TITLE%/$title_formated/gi;
			$custom_inform_command =~ s/%TITLE%/$matchunlc/gi;
		}
		print "Informing: ".$custom_inform_command."\n";
		next if $dry_run;
		system($custom_inform_command);

	# download torrents
	} elsif ($mtype == 2) {
		# if there are more torrents with the same name
		if ($find_alternative_torrent) {
			%torrent = find_alternative_torrent($match,%torrent);
			print "Alternative torrent: ".$torrent{'title'}."\n";
		}

		if ($dry_run) {
			push @history, $match;
			next;
		}

		# download torrent file
		my $get = LWP::UserAgent->new();
		$get->proxy('http', $proxy) if $proxy;
		$get->timeout(30);
		$get->show_progress(1);

		# download link is <link></link>
		my $link = $torrent{'link'};

		# use enclosure link if available (mininova, isohunt) 
		if ($torrent{'enclosure'} && $torrent{'enclosure'}{'url'}) {
			$link = $torrent{'enclosure'}{'url'}; 
		}

		# bit-hdtv.com: create/repair download links 
		if ($link =~ m/^http:\/\/(www\.)?bit-hdtv\.com\/details\.php\?id=([0-9]+)/i) {
			$link = 'http://www.bit-hdtv.com/download.php/'.$2.'/';
			my $torrent_title = $torrent{'title'}.'.torrent';
			$torrent_title =~ s/\s/\./g;
			$torrent_title =~ s/\.{2,}/\./g;
			$link .= $torrent_title; 
		}

		my $response = $get->get($link);

		# skip if download error
		if (!$response->is_success) {
			print "Download error\n";
			next;
		}


		# if downloaded content is not torrent file
		if ($response->header('content-type') !~/^application\/x-(bit)?torrent$/) {
			print "Wrong Content-Type\n".$response->header('content-type');
			next;
		}

		# get/set file name
		my $filename;
		if ($response->header('content-disposition') && $response->header('content-disposition') =~m/filename="?(.*?)"?$/gi) {
			$filename = $1;
		} elsif ($link =~m/.*\/(.*\.torrent)$/) {
			$filename = $1;
		} else {
			$filename = $match.'.torrent';
		}
		$filename =~s/\s//g;

		my $content = $response->content;

		# bit-hdtv.com: repair tracker announce url in the torrent file -> insert passkey
		if ($link =~ /^https?:\/\/(www\.)?bit-hdtv\.com\//i) {
			print "Replacing announce url (passkey in bit-hdtv.com)\n    ";
			$content =~ s/(.*)(\/announce)/d8:announce70:http:\/\/www.bit-hdtv.com:2710\/$bithdtv_passkey$2/i;
		}

		# save content as torrent file
		print "Saving torrent to: $torrent_save_dir/$filename\n    ";
		open TORRENT, '>', $torrent_save_dir.'/'.$filename || die('Could not save torrent file.'); 
		binmode TORRENT;
		print TORRENT $content;
		close TORRENT;

		if (-z $torrent_save_dir.'/'.$filename) {
			print "Strange, it looks like file was not saved.\n    ";
			next;
		}

		print "Saved:   ".$torrent_save_dir.'/'.$filename."\n";
	}

	# save history right away 
	push @history, $match;
	open(HISTORY, '>>', $history_file);
	print HISTORY $match."\n";
	close HISTORY;
}	

# try to find better alternatives for a specific torrent i.e.:
# isohunt has dynamic rss which is based on search and if it finds more 
# torrents this function tries to find which of these torrents is the best
# to download. size (>500MB) has a higher priority than peers count, but
# it takes higher quality torrents only if it has more >= 10 seeds.
# Originally written for TheDailyShow rips on isohunt to avoid small
# low quality torrents (170-190MB) if there are better alternatives with
# higher quality even if they have not so many peers. example url:
# http://isohunt.com/js/rss/daily+show+hdtv?iht=3
#
# works only on: ishunt.com
# it ignores torrents on other trackers
sub find_alternative_torrent {
	my $filter = shift;
	my %otorrent = @_;

	# isohunt
	if ($otorrent{'link'} =~/^https?:\/\/(www\.)?(isohunt\.com)\//i) {
		my @atorrents = grep { $_->{'title'} =~ /^$filter/i } @torrents;
		return %otorrent if $#atorrents < 1; 

		# get seeders and leechers
		foreach (@atorrents) {
			if ($_->{'title'} =~ /\[(\d+)\/(\d+)\]$/) {
				$_->{'seeds'} += $1;
				$_->{'leechers'} += $2;
			}
		}

		# sort torrents
		@atorrents = sort {
			if ($a->{'enclosure'}->{'length'} > 500000000 || $b->{'enclosure'}->{'length'} > 500000000) {
				if ($a->{'seeds'} > 9 && $b->{'seeds'} > 9)  {
					return $b->{'enclosure'}->{'length'} <=> $a->{'enclosure'}->{'length'};
				} elsif ($a->{'seeds'} > 9) {
					return -1;
				} elsif ($b->{'seeds'} > 9) {
					return 1;
				}
			}
			if ($a->{'seeds'} == $b->{'seeds'}) {
				return $b->{'leechers'} <=> $a->{'leechers'};
			}
			return $b->{'seeds'} <=> $a->{'seeds'};
		} @atorrents;

		# return first torrent
		return %{ shift @atorrents };
	}
	return %otorrent;
}

# return file in an array
# exclude comment, blank linkes etc.
sub read_file {
	my $file = shift;
	return () if (!$file || ! -e $file || ! -f $file || -d $file);

	open F, $file;
	my @lines = grep !/^(#.*|\s*)$/, <F>;
	chomp(@lines);
	close F;
	return @lines;
}

# remove useless info from torrent name
sub format_title {
	my $match = shift; 
	$match =~s/^(.*)((1080|720)p.*)$/$1/;
	$match =~s/\./ /g;
	$match =~s/(^|[^\w\-\'])([a-z])/$1\U$2/g;
	$match =~s/([sS][0-9]{2}[eE][0-9]{2})/\U$1/g;
	$match =~s/\s+$//g;
	$match =~s/^\s+//g;
	return $match;
}
