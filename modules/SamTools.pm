package SamTools;
use strict;
use Carp;
use File::Spec;
use File::Basename;
use Cwd;
use Digest::MD5  qw(md5 md5_hex md5_base64);
use Utils;

use AssemblyTools;

=pod

=head1 DATA STRUCTURES

$FLAGS

=cut

our $FLAGS = 
{
    'paired_tech'    => 0x0001,
    'read_mapped'    => 0x0002,     # This name is confusing, should be called mapped_in_pair instead.
    'unmapped'       => 0x0004,
    'mate_unmapped'  => 0x0008,
    'reverse_strand' => 0x0010,
    'mate_reverse'   => 0x0020,
    '1st_in_pair'    => 0x0040,
    '2nd_in_pair'    => 0x0080,
    'not_primary'    => 0x0100,
    'failed_qc'      => 0x0200,
    'duplicate'      => 0x0400,
};

sub bam_stat_fofn
{
    croak "Usage: bam_stat bam_fofn\n" unless @_ == 1;
    my $bam_fofn = shift;
    
    croak "Cant find bam_fofn file: $bam_fofn\n" unless -f $bam_fofn;
    
    open( F, $bam_fofn ) or die "cant open bam fofn: $bam_fofn\n";
    while( <F> )
    {
        chomp;
        if( -f $_ )
        {
            my $statF = $_."bamstat";
            my $cmd = qq[bsub -q normal -o $$.bam.o -e $$.bam.e perl -w -e "use SamTools;SamTools::bam_stat( '$_', '$statF');"];
            #print $cmd."\n";
            system( $cmd );
        }
        else
        {
            print "Cant find BAM file: $_\n";
        }
    }
    close( F );
}

sub bam_stat
{
    croak "Usage: bam_stat bam output_file\n" unless @_ == 2;
    my $bam = shift;
    my $output = shift;
    
    my $numReads = 0;
    my $numBases = 0;
    my $insert_mean = 0;
    open( BAM, "samtools view $bam |" ) or die "Cannot open bam file: $bam\n";
    while( <BAM> )
    {
        chomp;
        my @s = split( /\s+/, $_ );
        # only consider reads that actually mapped
        next if ($s[1] & $FLAGS->{unmapped});
        $numBases += length( $s[ 9 ] );
        my $ins = abs( $s[ 8 ] );
        $insert_mean = ( ( $insert_mean * $numReads ) + $ins ) / ( $numReads + 1 ) unless $ins > 10000 && $ins != 0;
        $numReads ++;
    }
    close( BAM );
    
    #do a second pass to get the std deviations (uses too much memory if store all inserts in memory)
    my $sumSqVariances = 0;
    open( BAM, "samtools view $bam |" ) or die "Cannot open bam file: $bam\n";
    while( <BAM> )
    {
        chomp;
        my @s = split( /\s+/, $_ );
        my $ins = abs( $s[ 8 ] );
        $sumSqVariances += ( ( $insert_mean - $ins ) * ( $insert_mean - $ins ) ) unless $ins > 10000 && $ins != 0;
    }
    close( BAM );
    
    my $std = $sumSqVariances ? sqrt( ( $sumSqVariances / $numReads ) ) : 0;
    
    open( O, ">$output" ) or die "Cannot create output: $!\n";
    print O "num_bases:$numBases\n";
    print O "num_reads:$numReads\n";
    print O "avg_insert:$insert_mean\n";
    print O "std_dev:$std\n";
    close( O );
}

sub parse_bam_header_line
{
    my ($line) = @_;
    my $out = {};

    # Header line:
    #   @RG     ID:ERR001773    PL:ILLUMINA     PU:IL23_337_6   LB:g1k-sc-NA12878-CEU-2 PI:200  SM:NA12878      CN:SC
    my @items = split /\t/, $line;
    shift(@items);
    for my $pair (@items)
    {
        my ($key,$value) = split /:/,$pair;
        $$out{$key} = $value;
    }
    return $out;
}

sub parse_bam_line
{
    my ($line) = @_;
    my $out = {};

    #   IL14_1902:3:83:1158:1446        89      1       23069154        37      54M     =       23069154        0       TGCAC ... RG:Z:ERR001720
    my @items = split /\t/, $line;

    $$out{'flag'}  = $items[1];
    $$out{'chrom'} = $items[2];
    $$out{'pos'}   = $items[3];
    $$out{'cigar'} = $items[5];
    $$out{'isize'} = $items[8];
    $$out{'seq'}   = $items[9];

    my $nitems = @items;
    for (my $i=11; $i<$nitems; $i++)
    {
        my ($key,@vals) = split /:/,$items[$i];

        # e.g. RG:Z:ERR001720
        if ( $key eq 'RG' )
        {
            $$out{'RG'} = $vals[1];
        }

        # e.g. NM:i:0
        elsif( $key eq 'NM' )
        {
            $$out{'NM'} = $vals[1];
        }
    }
    return $out;
}


=head2 collect_detailed_bam_stats

        Description: Reads the given bam file and runs detailed statistics, such as 
                        histograms of insert size; QC content of mapped and both mapped
                        and unmapped sequences; reads distribution with respect to
                        chromosomes; duplication rate.
        Arg [1]    : The .bam file (sorted and indexed).
        Arg [2]    : The .fai file (to determine chromosome lengths). (Can be NULL with do_chrm=>0.)
        Arg [3]    : Options (hash) [Optional]
        Options    : (see the code for default values)
                        do_chrm          .. should collect the chromosome distrib. stats.
                        do_gc_content    .. should we collect the gc_content (default is 1)
                        do_rmdup         .. default is 1 (calculate the rmdup); alternatively supply the filename of a pre-calculated rmdup

                        insert_size_bin  .. the length of the distribution intervals for the insert size frequencies
                        gc_content_bin   

        Returntype : Hash with the following entries, each statistics type is a hash as well. See also Graphs::plot_stats.
                        insert_size =>
                            yvals      .. array of insert size frequencies 
                            xvals      .. 
                            max => x   .. maximum values
                            max => y
                            average    .. average value (estimated from histogram, the binsize may influence the accuracy)
                        gc_content_forward  .. gc content of sequences with the 0x0040 flag set
                        gc_content_reverse  .. gc content of seqs with the 0x0080 flag set
                        reads_chrm_distrib  .. read distribution with respect to chromosomes
                        reads_total
                        reads_paired
                        reads_mapped        .. paired + unpaired
                        reads_unpaired
                        reads_unmapped
                        bases_total
                        bases_mapped
                        duplication
                        num_mismatches (if defined in bam file, otherwise 0)
=cut

sub collect_detailed_bam_stats
{
    my ($bam_file,$fai_file,$options) = @_;
    if ( !$bam_file ) { Utils::error("Expected .bam file as a parameter.\n") }
    
    $options = {} unless $options;
    my $insert_size_bin = exists($$options{'insert_size_bin'}) ? $$options{'insert_size_bin'} : 1;
    my $gc_content_bin  = exists($$options{'gc_content_bin'}) ? $$options{'gc_content_bin'} : 1;

    my $do_chrm  = exists($$options{'do_chrm'}) ?  $$options{'do_chrm'} : 1;
    my $do_gc    = exists($$options{'do_gc_content'}) ? $$options{'do_gc_content'} : 1;
    my $do_rmdup = exists($$options{'do_rmdup'}) ? $$options{'do_rmdup'} : 1;

    my $chrm_lengths = $do_chrm ? Utils::fai_chromosome_lengths($fai_file) : {};

    # Use hashes, not arrays - the data can be broken and we might end up allocating insanely big arrays 

    #   reads_unmapped  ..   That is, not aligned to the ref sequence (unmapped flag)
    #   reads_paired    ..      both mates are mapped and form a pair (read_mapped flag)
    #   reads_unpaired  ..      both mates mapped, but do not form a pair (neither unmapped nor read_mapped flag set)
    #   bases_total     ..   The total number of bases determined as \sum_{seq} length(seq)
    #   bases_mapped    ..      number of bases with 'M' in cigar

    my $raw_stats = {};

    # Collect the statistics - always collect the total statistics for all lanes ('total') and
    #   when the RG information is present in the header, collect also statistics individually
    #   for each ID (@RG ID:xyz). The statistics are collected into raw_stats hash, individual
    #   keys are 'total' and IDs.
    #
    my $i=0;
    open(my $fh, "samtools view -h $bam_file |") or Utils::error("samtools view -h $bam_file |: $!");
    while (my $line=<$fh>)
    {
        # Header line:
        #   @RG     ID:ERR001773    PL:ILLUMINA     PU:IL23_337_6   LB:g1k-sc-NA12878-CEU-2 PI:200  SM:NA12878      CN:SC
        #
        # Data line:
        #   IL14_1902:3:83:1158:1446        89      1       23069154        37      54M     =       23069154        0       TGCAC ... RG:Z:ERR001720
        #
        if ( $line=~/^\@/ )
        {
            if ( !($line=~/^\@RG/) ) { next }

            my $header = parse_bam_header_line($line);
            if ( !exists($$header{'ID'}) ) { Utils::error("No ID in the header line? $line\n"); }

            $$raw_stats{$$header{'ID'}}{'header'} = $header;
            next;
        }
		
        # The @stats array is a convenient way how to reuse the same code for the total and individual
        #   statistics - we will always add the same numbers to 'total' and the ID.
        #
        my @stats = ('total');
        my $data  = parse_bam_line($line);
        if ( exists($$data{'RG'}) ) { push @stats, $$data{'RG'}; }

        my $flag  = $$data{'flag'};
        my $chrom = $$data{'chrom'};
        my $pos   = $$data{'pos'};
        my $cigar = $$data{'cigar'};
        my $isize = $$data{'isize'};
        my $seq   = $$data{'seq'};
        
        my $seq_len  = length($seq);
        my $mismatch = exists($$data{'NM'}) ? $$data{'NM'} : 0;
        for my $stat (@stats)
        {
            $$raw_stats{$stat}{'reads_total'}++;
            $$raw_stats{$stat}{'bases_total'} += $seq_len;
            $$raw_stats{$stat}{'num_mismatches'} += $mismatch;
        }

        my $paired = ($flag & $$FLAGS{'read_mapped'}) && ($flag & $$FLAGS{'paired_tech'});
        if ( $paired || !($flag & $$FLAGS{'paired_tech'}) )
        {
            if ( $paired ) 
            { 
                for my $stat (@stats) { $$raw_stats{$stat}{'reads_paired'}++; }

                # Insert Size Frequencies
                #
                my $bin = abs(int( $isize / $insert_size_bin ));
                for my $stat (@stats) { $$raw_stats{$stat}{'insert_size_freqs'}{$bin}++; }
            }

            my $cigar_info = cigar_stats($cigar);
            if ( exists($$cigar_info{'M'}) )
            {
                for my $stat (@stats) { $$raw_stats{$stat}{'bases_mapped'} += $$cigar_info{'M'}; }
            }

            # Chromosome distribution
            #
            if ( $do_chrm && $chrom=~/^(?:\d+|X|Y)$/i ) 
            {
                for my $stat (@stats) { $$raw_stats{$stat}{'chrm_distrib_freqs'}{$chrom}++; }
            }
        }
        elsif ( $flag & $$FLAGS{'unmapped'} ) 
        { 
            for my $stat (@stats) { $$raw_stats{$stat}{'reads_unmapped'}++;  }
        }
        else 
        { 
            for my $stat (@stats) { $$raw_stats{$stat}{'reads_unpaired'}++; }

            my $cigar_info = cigar_stats($cigar);
            if ( exists($$cigar_info{'M'}) )
            {
                for my $stat (@stats) { $$raw_stats{$stat}{'bases_mapped'} += $$cigar_info{'M'}; }
            }
        }

        # GC Content Frequencies - collect stats for both pairs separately
        if ( $do_gc )
        {
            my $gc_count = 0;
            for (my $ipos=0; $ipos<$seq_len; $ipos++)
            {
                my $nuc  = substr($seq, $ipos, 1);
                if ( $nuc eq 'g' || $nuc eq 'G' || $nuc eq 'c' || $nuc eq 'C' ) { $gc_count++; }
            }
            $gc_count = $gc_count*100./$seq_len;
            my $bin = abs(int( $gc_count / $gc_content_bin ));
            if ( $flag & $$FLAGS{'1st_in_pair'} )
            {
                for my $stat (@stats) { $$raw_stats{$stat}{'gc_content_fwd_freqs'}{$bin}++; }
            }
            elsif ( $flag & $$FLAGS{'2nd_in_pair'} )
            {
                for my $stat (@stats) { $$raw_stats{$stat}{'gc_content_rev_freqs'}{$bin}++; }
            }
            elsif ( !($flag & $$FLAGS{'paired_tech'}) )  # Not a paired-read technology
            { 
                # Either it is a non-paired-read technology, or the 1st_in_pair and
                #   and 2nd_in_pair flags got lost in the process. (The specs allows this.)
                for my $stat (@stats) { $$raw_stats{$stat}{'gc_content_fwd_freqs'}{$bin}++; }
            }
        }

        #if ( $i++>50000 ) { last }
    }
    close $fh;

    # This sanity check could be used for paired reads only.
    #
    #   if ( ($flag & $$FLAGS{'paired_tech'}) && $reads_total != $reads_paired + $reads_unmapped + $reads_unpaired )
    #   {
    #       Utils::error("FIXME: Incorrect assumption: paired + unpaired + unmapped != total ($reads_paired+$reads_unpaired+$reads_unmapped!=$reads_total)\n");
    #   }
    #
    # This calculation worked only for paired reads.
    #   my $reads_mapped = $reads_unpaired + $reads_paired;
    #
    for my $stat (keys %$raw_stats) 
    { 
        $$raw_stats{$stat}{'reads_unmapped'} = 0 unless exists($$raw_stats{$stat}{'reads_unmapped'});
        $$raw_stats{$stat}{'reads_unpaired'} = 0 unless exists($$raw_stats{$stat}{'reads_unpaired'});
        $$raw_stats{$stat}{'reads_paired'}   = 0 unless exists($$raw_stats{$stat}{'reads_paired'});
        $$raw_stats{$stat}{'reads_total'}    = 0 unless exists($$raw_stats{$stat}{'reads_total'});

        $$raw_stats{$stat}{'reads_mapped'} = $$raw_stats{$stat}{'reads_total'} - $$raw_stats{$stat}{'reads_unmapped'}; 
    }

    # Find out the duplication rate
    if ( $do_rmdup )
    {
        my $rmdup_reads_total;
        if (-f $do_rmdup && -s $do_rmdup) {
            chomp(($rmdup_reads_total) = Utils::CMD("wc -l $do_rmdup"));
        }
        else {
            chomp(($rmdup_reads_total) = Utils::CMD("samtools rmdup $bam_file - 2>/dev/null | samtools view - | wc -l"));
        }
        $$raw_stats{'total'}{'rmdup_reads_total'} = $rmdup_reads_total;
    }

    # Now process the reults. The raw_stats hash now contains the total statistics (the key 'total')
    #   and possibly also separate statistics for individual libraries (other keys, e.g. 'ERR001773').
    #
    my $stats = {};
    for my $stat (keys %$raw_stats)
    {
        $$stats{$stat} = 
        {
            'reads_total'       => $$raw_stats{$stat}{'reads_total'},
            'reads_paired'      => $$raw_stats{$stat}{'reads_paired'},
            'reads_mapped'      => $$raw_stats{$stat}{'reads_mapped'},
            'reads_unpaired'    => $$raw_stats{$stat}{'reads_unpaired'},
            'reads_unmapped'    => $$raw_stats{$stat}{'reads_unmapped'},
            'bases_total'       => $$raw_stats{$stat}{'bases_total'},
            'bases_mapped'      => $$raw_stats{$stat}{'bases_mapped'},
            'num_mismatches'    => $$raw_stats{$stat}{'num_mismatches'},

            'insert_size' => 
            {
                'data'       => $$raw_stats{$stat}{'insert_size_freqs'},
                'bin_size'   => $insert_size_bin,
            },
        };
        if ( exists($$raw_stats{$stat}{'header'}) )
        {
            $$stats{$stat}{'header'} = $$raw_stats{$stat}{'header'};
        }
        if ( exists($$raw_stats{$stat}{'chrm_distrib_freqs'}) )
        {
            $$stats{$stat}{'chrm_distrib_freqs'} = $$raw_stats{$stat}{'chrm_distrib_freqs'};
        }
        if ( exists($$raw_stats{$stat}{'rmdup_reads_total'}) )
        {
            $$stats{$stat}{'rmdup_reads_total'} = $$raw_stats{$stat}{'rmdup_reads_total'};
            $$stats{$stat}{'duplication'}       = $$raw_stats{$stat}{'rmdup_reads_total'}/$$raw_stats{$stat}{'reads_total'};
        }
        if ( exists($$raw_stats{$stat}{'gc_content_fwd_freqs'}) )
        {
            $$stats{$stat}{'gc_content_forward'} = 
            {
                'data'       => $$raw_stats{$stat}{'gc_content_fwd_freqs'},
                'bin_size'   => $gc_content_bin,
            };
        }
        if ( exists($$raw_stats{$stat}{'gc_content_rev_freqs'}) )
        {
            $$stats{$stat}{'gc_content_reverse'} =
            {
                'data'       => $$raw_stats{$stat}{'gc_content_rev_freqs'},
                'bin_size'   => $gc_content_bin,
            };
        }
    }

    # Convert the hashes into arrays and find extreme values - this is for convenience only,
    #   TrackQC uses this. Although the code is lengthy, the histograms are small and take
    #   no time to process.
    #
    for my $stat_name (keys %$stats)
    {
        my $stat = $$stats{$stat_name};

        for my $key (keys %$stat)
        {
            if ( ref($$stat{$key}) ne 'HASH' ) { next }
            if ( !exists($$stat{$key}{'data'}) ) { next }
            if ( !exists($$stat{$key}{'bin_size'}) ) { next }

            my @yvals = ();
            my @xvals = ();
            my ($ymax,$xmax);

            my $avg  = 0;
            my $navg = 0;

            my $data = $$stat{$key}{'data'};
            for my $ibin (sort {$a<=>$b} keys %$data)
            {
                my $bin = $ibin * $$stat{$key}{'bin_size'};
                if ( $$stat{$key}{'bin_size'}>1 ) { $bin += $$stat{$key}{'bin_size'}*0.5; }
                push @xvals, $bin;

                my $yval = $$data{$ibin};
                push @yvals, $yval;

                $avg  += $yval*$bin;    # yval is the count and bin the value
                $navg += $yval;

                if ( !defined $ymax || $yval>$ymax ) { $xmax=$bin; $ymax=$yval }
            }
            $$stat{$key}{'xvals'} = scalar @xvals ? \@xvals : [0];  # Yes, this can happen,e.g. AKR_J_SLX_200_NOPCR_1/1902_3
            $$stat{$key}{'yvals'} = scalar @yvals ? \@yvals : [0];
            $$stat{$key}{'max'}{'x'} = defined $xmax ? $xmax : 0;
            $$stat{$key}{'max'}{'y'} = defined $ymax ? $ymax : 0;
            $$stat{$key}{'average'}  = $navg ? $avg/$navg : 0;
        }

        # Chromosome distribution histograms (reads_chrm_distrib) are different - xvalues are not numeric
        #
        if ( exists($$stat{'chrm_distrib_freqs'}) )
        {
            my @yvals = ();
            my @xvals = ();
            for my $key (sort Utils::cmp_mixed keys %{$$stat{'chrm_distrib_freqs'}})
            {
                if ( !exists($$chrm_lengths{$key}) ) { Utils::error("The chromosome \"$key\" not in $fai_file.\n") }
                push @yvals, $$stat{'chrm_distrib_freqs'}{$key} / $$chrm_lengths{$key};
                push @xvals, $key;
            }   
            $$stat{'reads_chrm_distrib'}{'yvals'} = scalar @yvals ? \@yvals : [0];
            $$stat{'reads_chrm_distrib'}{'xvals'} = scalar @xvals ? \@xvals : [0];
            $$stat{'reads_chrm_distrib'}{'scaled_dev'} = scaled_chrm_dev(\@xvals,\@yvals);
        }
    }
    
    return $stats;
}


# Calculates some sort of standard devitation, except that the
#   the difference from mean is scaled by mean (so that the formula
#   works for samples of different size) and the instead of mean
#   the maximum is used (we want to detect one oversampled chromosome): 
#       sqrt[(1/N)*sum_i((y_i-max)/max)**2]
#
sub scaled_chrm_dev
{
    my ($xvals,$yvals) = @_;
    my $max   = 0;
    my $ndata = 0;
    for (my $i=0; $i<scalar @$xvals; $i++)
    {
        # We do not know if both chromosome X and Y should be counted - we don't know the sex
        if ( !($$xvals[$i]=~/^\d+$/) ) { next } 

        if ( !defined($max) || $max<$$yvals[$i] ) { $max=$$yvals[$i]; }
        $ndata++;
    }
    if ( !$ndata ) { return 0 }

    my $stddev = 0;
    for (my $i=0; $i<scalar @$xvals; $i++)
    {
        if ( !($$xvals[$i]=~/^\d+$/) ) { next } 

        $stddev += (($$yvals[$i] - $max)/$max)**2;
    }
    return sqrt($stddev/$ndata);
}


=head2 cigar_stats

        Description: Parse the SAM cigar and return some info.
        Arg [1]    : The cigar (e.g. 36M, 5M1I30M, 21M15S, etc.)
        Returntype : The hash e.g. { 'M'=>35, 'I'=>1 } 

=cut

sub cigar_stats
{
    my ($cigar) = @_;

    my $stats = {};
    while ($cigar)
    {
        if ( !($cigar=~/^(\d+)(\D)/) ) { last }
        $$stats{$2} += $1;
        $cigar = $';
    }

    return $stats;
}


=head2 print_flags

        Description: For debugging purposes, prints flags for all sequences in human readable form.
        Arg [1]    : The .bam file (sorted and indexed).
        Returntype : None

=cut

sub print_flags
{
    my ($bam_file,$options) = @_;

    if ( !$options ) { $options='' }

    my $fh = \*STDIN;
    if ( $bam_file ) { open($fh, "samtools view $bam_file $options |") or Utils::error("samtools view $bam_file $options |: $!"); }
    while (my $line=<$fh>)
    {
        # IL14_1902:3:83:1158:1446        89      1       23069154        37      54M     =       23069154        0       TGCAC
        my @items = split /\t/, $line;
        my $flag  = $items[1];
        my $chrom = $items[2];
        my $pos   = $items[3];
        my $isize = $items[8];
        my $seq   = $items[9];

        print $line;
        print "\t insert_size=$isize flag=$flag\n\t --\n";
        print debug_flag($flag);
        print "\n";
    }
    close $fh;
    return;
}

sub debug_flag
{
    my ($flag) = @_;

    my $out = '';
    for my $key (sort keys %$FLAGS)
    {
        if ( $flag & $$FLAGS{$key} ) { $out .= "\t $key\n" }
    }
    return $out;
}


=head2 determineUnmappedFlag

    Arg [1]    : 1/0 flag to say whether the lane is a paired lane
    Arg [2]    : -1/0/1 flag of whether the read is the first read of a pair
    Example    : determineUnmappedFlag( 0, 1 );
    Description: works out the SAM flag value for an unmapped read
    Returntype : int
=cut
sub determineUnmappedFlag
{
    croak "Usage: determineUnmappedFlag paired(0/1) read1(-1/0/1)\n" unless @_ == 2;
    
    my $paired = shift;
    my $read1 = shift;
    
    croak "Paired flag must be 0 or 1\n" unless $paired == 0 || $paired == 1;
    
    croak "Read1 flag must be -1, 0 or 1\n" unless $read1 == 0 || $read1 == 1 || $read1 == -1;
    
    my $total = $paired == 1 ? hex( '0x0001' ) : 0;
    $total += hex( '0x0004' );
    $total += hex( '0x0008' );
    
    if( $paired == 1 )
    {
        #if the read is a fragment from an paired run - then it wont be either end of a pair (e.g. 454)
        if( $read1 != -1 )
        {
            $total += $read1 == 1 ? hex( '0x0040' ) : hex( '0x0080' );
        }
    }
    
    return $total;
}

=head2 pileup2Intervals

    Arg [1]    : samtools pileup file
    Arg [2]    : sam header file
    Arg [3]    : output intervals file
    Example    : pileup2Intervals
    Description: creates an intervals file for the broad recalibrator which excludes all positions +/- 20bp around all indels
    Returntype : none
=cut

sub pileup2Intervals
{
    croak "Usage: pileup2Intervals samtools_pileup_file sam_header_file output_file\n" unless @_ == 3;
    
    my $pileup = shift;
    my $sam_header = shift;
    my $output = shift;
    
    croak "Cant find pileup file: $pileup" unless -f $pileup;
    croak "Cant find sam header file: $sam_header" unless -f $sam_header;
    
    my $pfh;
    if( $pileup =~ /\.gz$/ )
    {
        open( $pfh, "gunzip -c $pileup |" ) or die "Cannot open pileup file: $!\n";
    }
    else
    {
        open( $pfh, $pileup ) or die "Cannot open pileup file: $!\n";
    }
    
    system( qq[cat $sam_header > $output] );
    
    open( my $out, ">>$output" ) or die "Cannot create output file: $!\n";
    my $currentStartPos = 1;
    my $c = 0;
    
    my $currentChr = 'none';
    while( <$pfh> )
    {
        chomp;
        if( $_ =~ /^.+\t\d+\t\*\t.*/ )
        {
            my @s = split( /\t/, $_ );
            
            if( $currentChr eq 'none' || $currentChr ne $s[ 0 ] )
            {
                $currentChr = $s[ 0 ];
                $currentStartPos = 1;
            }
            
            my $stop = $s[ 1 ] - 20;
            
            if( $stop > $currentStartPos )
            {
                print $out qq/$s[ 0 ]\t$currentStartPos\t$stop\t+\ttarget_$c\n/;
                $currentStartPos = $s[ 1 ] + 20;
                $c ++;
            }
        }
    }
    close( $pfh );
    close( $out );
}

1;
