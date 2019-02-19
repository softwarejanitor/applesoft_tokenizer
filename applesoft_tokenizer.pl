#!/usr/bin/perl -w

use strict;

my $debug = 0;

my $BUFSIZ = 1024;

my $lnk_offset = 0;
my $lnk_value = 0x801;  # Default start of Applesoft program.
my $cust_offset = 0;

# An Applesoft file in memory by default starts at address $801
# First two butes are size (lo byte first).
# Then each line is as follows:
#    2 bytes (lo byte first) of link to address of next line.
#    2 bytes (lo byte first) of the line number.
#    A sequence of ASCII bytes (high bit clear, unlike most Apple II files) or tokens (see hash below)
#    0x00 indicates end of line
# File ends with 0x00 0x00

my %tokens = (
  "END"     => 128,
  "FOR"     => 129,
  "NEXT"    => 130,
  "DATA"    => 131,
  "INPUT"   => 132,
  "DEL"     => 133,
  "DIM"     => 134,
  "READ"    => 135,
  "GR"      => 136,
  "TEXT"    => 137,
  "PR#"     => 138,
  "IN#"     => 139,
  "CALL"    => 140,
  "PLOT"    => 141,
  "HLIN"    => 142,
  "VLIN"    => 143,
  "HGR2"    => 144,
  "HGR"     => 145,
  "HCOLOR=" => 146,
  "HPLOT"   => 147,
  "DRAW"    => 148,
  "XDRAW"   => 149,
  "HTAB"    => 150,
  "HOME"    => 151,
  "ROT="    => 152,
  "SCALE="  => 153,
  "SHLOAD"  => 154,
  "TRACE"   => 155,
  "NOTRACE" => 156,
  "NORMAL"  => 157,
  "INVERSE" => 158,
  "FLASH"   => 159,
  "COLOR="  => 160,
  "POP"     => 161,
  "VTAB"    => 162,
  "HIMEM:"  => 163,
  "LOMEM:"  => 164,
  "ONERR"   => 165,
  "RESUME"  => 166,
  "RECALL"  => 167,
  "STORE"   => 168,
  "SPEED="  => 169,
  "LET"     => 170,
  "GOTO"    => 171,
  "RUN"     => 172,
  "IF"      => 173,
  "RESTORE" => 174,
  "&"       => 175,
  "GOSUB"   => 176,
  "RETURN"  => 177,
  "REM"     => 178,
  "STOP"    => 179,
  "ON"      => 180,
  "WAIT"    => 181,
  "LOAD"    => 182,
  "SAVE"    => 183,
  "DEF"     => 184,
  "POKE"    => 185,
  "PRINT"   => 186,
  "CONT"    => 187,
  "LIST"    => 188,
  "CLEAR"   => 189,
  "GET"     => 190,
  "NEW"     => 191,
  "TAB"     => 192,
  "TO"      => 193,
  "FN"      => 194,
  "SPC("    => 195,
  "THEN"    => 196,
  "AT"      => 197,
  "NOT"     => 198,
  "STEP"    => 199,
  "+"       => 200,
  "-"       => 201,
  "*"       => 202,
  "/"       => 203,
  "^"       => 204,
  "AND"     => 205,
  "OR"      => 206,
  ">"       => 207,
  "="       => 208,
  "<"       => 209,
  "SGN"     => 210,
  "INT"     => 211,
  "ABS"     => 212,
  "USR"     => 213,
  "FRE"     => 214,
  "SCRN"    => 215,
  "PDL"     => 216,
  "POS"     => 217,
  "SQR"     => 218,
  "RND"     => 219,
  "LOG"     => 220,
  "EXP"     => 221,
  "COS"     => 222,
  "SIN"     => 223,
  "TAN"     => 224,
  "ATN"     => 225,
  "PEEK"    => 226,
  "LEN"     => 227,
  "STR\$"   => 228,
  "VAL"     => 229,
  "ASC"     => 230,
  "CHR\$"   => 231,
  "LEFT\$"  => 232,
  "RIGHT\$" => 233,
  "MID\$"   => 234,
);

# Reverse sort the keys to prevent ATN being turned into AT N
my @tokenstrs = reverse sort keys %tokens;

# Reasonable max sizeof Applesoft program = 48k - 2k.
my $MAX_SIZE = 47104;

# Bytes for output storage.
my @output;

my $line_count = 0;
my $line;

my $in_quoted_str = 0;
my $in_remark = 0;

# Return low byte.
sub low_byte {
  my ($x) = @_;

  return ($x & 0xff);
}

# Return high byte.
sub high_byte {
  my ($x) = @_;

  return (($x >> 8) & 0xff);
}

sub check_progsize {
  my ($size) = @_;

  if ($size > $MAX_SIZE) {
    die "Output file too big!\n";
  }
}

sub find_token {
  my ($rest) = @_;

  my $ch = substr($rest, 0, 1);

  if ($in_remark && ($ch eq "\n")) {
    $rest = '';
    $_[0] = $rest;
    $in_remark = 0;
    return 0;
  }

  # Son't skip whitespace in quoted strings or REMs.
  if ((!$in_quoted_str) && (!$in_remark)) {
    while ($ch eq ' ') {
      if (length($rest)) {
        $rest = substr($rest, 1);
        $ch = substr($rest, 0, 1);
        if (($ch eq "\n") || ($ch eq "\r") || ($ch eq "\0")) {
          return 0;
        }
      } else {
        $ch = '';
        $rest = '';
      }
    }
  }

  # Toggle quotes on or off.
  if ($ch eq '"') {
    $in_quoted_str = !$in_quoted_str;
    print "Toggling quotes\n" if $debug;
  }

  # Don't tokenize when in quoted strings or REMs.
  if (!$in_quoted_str && !$in_remark) {
    foreach my $tokstr (@tokenstrs) {
      next if $tokstr eq '';
      if (substr($rest, 0, length($tokstr)) eq $tokstr) {
        my $rest = substr($rest, length($tokstr));
        $_[0] = $rest;

        if ($tokstr eq 'REM') {
          $in_remark = 1;
        }

        print sprintf("Found token '$tokstr' \$%02x\n", $tokens{$tokstr}) if $debug;

        return $tokens{$tokstr};
      }
    }
  }

  if (length($rest)) {
    $rest = substr($rest, 1);
  }
  $_[0] = $rest;
  return ord($ch);
}

sub tokenize {
  my ($ifh, $ofh) = @_;

  # First line.
  my $prev_line = 0;

  # Start past the initial size.
  my $offset = 2;

  # Get lines from input file.
  while (my $line = readline $ifh) {
    $line_count++;
    $in_remark = 0;
    $in_quoted_str = 0;
    print "line_count=$line_count line=$line\n" if $debug;

    # Skip empty input lines.
    next if $line =~ /^\s*$/;

    if ($line =~ /^\s*(\d+)\s+(.+)/) {
      my $line_no = $1;
      my $rest = $2;

      if (($line_no > 65535) || ($line_no < 0)) {
        die sprintf("Invalid line number %d\n", $line_no);
      }
      if ($line_no < $prev_line) {
        die sprintf("Line counted backwards %d->%d\n", $prev_line, $line_no);
      }
      $prev_line = $line_no;

      # Keep track of current link offset.
      $lnk_offset = $offset;

      check_progsize($offset + 4);

      # Add the line number to the output
      $output[$offset + 2] = low_byte($line_no);
      $output[$offset + 3] = high_byte($line_no);
      $offset += 4;

      # Now process the rest of the line.
      while (1) {
        my $token = find_token($rest);
        if (defined $token) {
          $output[$offset] = $token;
          print STDERR sprintf("%2X ", $token) if ($debug);
          $offset++;
          check_progsize($offset);
          if ($rest eq '') {
            $output[$offset] = 0x00;
            $offset++;
            last;
          }
        }
      }
    } else {
      print "Unable to parse\n";
    }

    # Remarks end at end of line.
    $in_remark = 0;

    # 2 bytes is to ignore size from beginning of file.
    $lnk_value = 0x801 + ($offset - 2);

    check_progsize($offset + 2);

    # Point link value to next line.
    if ($cust_offset) {
      $output[$lnk_offset] = low_byte($cust_offset);
      $output[$lnk_offset + 1] = high_byte($cust_offset);
      print sprintf("Outputting link offset \$%02x \$%02x\n", low_byte($cust_offset), high_byte($cust_offset)) if $debug;
    } else {
      $output[$lnk_offset] = low_byte($lnk_value);
      $output[$lnk_offset + 1] = high_byte($lnk_value);
      print sprintf("Outputting link offset \$%02x \$%02x\n", low_byte($lnk_value), high_byte($lnk_value)) if $debug;
    }
  }

  # Set last link field to $00 $00 which indicates EOF.
  check_progsize($offset + 2);
  $output[$offset] = 0x00;
  $output[$offset + 1] = 0x00;
  print "Outputting ending zeros\n" if $debug;
  $offset += 2;

  # Set filesize = offset - 1 to match observed values.
  $output[0] = low_byte($offset - 1);
  $output[1] = high_byte($offset - 1);
  print sprintf("Outputting file size \$%02x \$%02x\n", low_byte($offset - 1), high_byte($offset - 1)) if $debug;

  # Output the file.
  print sprintf("offset=%d \$%04x\n", $offset, $offset) if $debug;
  for (my $i = 0; $i < $offset; $i++) {
    print $ofh pack "C", $output[$i];
    if ($debug) {
       print sprintf("\n%04x ", $i) if (!($i % 16));
       print sprintf(" %02x ", $output[$i]);
    }
  }
  print "\n" if $debug;
}

my $in_file = shift or die "Must supply input filename\n";
my $out_file = shift or die "Must supply output filename\n";

my $ifh;
my $ofh;

if (open($ifh, "<$in_file")) {
  if (open($ofh, ">$out_file")) {
    tokenize($ifh, $ofh);

    close $ofh;
  } else {
    die "Unable to write $out_file\n";
  }

  close $ifh;
} else {
  die "Unable to open $in_file\n";
}

1;

