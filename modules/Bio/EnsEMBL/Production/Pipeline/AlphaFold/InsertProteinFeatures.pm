=head1 LICENSE

 Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
 Copyright [2016-2023] EMBL-European Bioinformatics Institute

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

 Questions may also be sent to the Ensembl help desk at
 <http://www.ensembl.org/Help/Contact>.

=head1 NAME

 Bio::EnsEMBL::Production::Pipeline::AlphaFold::InsertProteinFeatures

=head1 DESCRIPTION

 This module inserts protein features into an Ensembl core database based on
 GIFTS data or the UniParc accessions that are present in the core DB. The
 protein features link to an Alphafold accession.

 For species where we have data in the GIFTS DB, we use this, because we assume
 this to be of higher quality. In this case we fetch a mapping from Ensembl
 stable ID of the transcript (ENST...) to UniProt accession for the protein
 (Q98C45).

 For species not in GIFTS, we fetch the UniParc IDs (UPI00...) from the core DB,
 where we have them as xrefs. We then use a DB to map the UniParc IDs to UniProt
 IDs.

 The next steps are now the same for both cases. With the UniProt accession, we
 select the matching Alphafold accession and associated information and insert
 new protein features based on this data.

=head1 OPTIONS

 -cs_version     Coordinate system version.
 -species        Production name of species to process
 -db_dir         Path to the uniparc-to-uniprot DB and the uniprot-to-alpha DB, both in LevelDB format
 -rest_server    GIFTS rest server to fetch the perfect matches data from.

=head1 EXAMPLE USAGE

 standaloneJob.pl Bio::EnsEMBL::Production::Pipeline::AlphaFold::InsertProteinFeatures
  -cs_version GRCh38
  -species homo_sapiens
  -db_dir /hps/scratch/...
  -rest_server 'https://www.ebi.ac.uk/gifts/api/'
  -registry my_reg.pm

=cut

package Bio::EnsEMBL::Production::Pipeline::AlphaFold::InsertProteinFeatures;

use strict;
use warnings;

use parent 'Bio::EnsEMBL::Production::Pipeline::Common::Base';

use Bio::EnsEMBL::Utils::Exception qw(throw info);
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::GIFTS::DB qw(fetch_latest_uniprot_enst_perfect_matches);
use Bio::EnsEMBL::ProteinFeature;
use Tie::LevelDB;
use Fcntl qw(:flock);

sub fetch_input {
    my $self = shift;

    $self->param_required('cs_version');
    $self->param_required('species');
    $self->param_required('rest_server');
    $self->param_required('db_dir');

    return 1;
}

sub run {
    my $self = shift;
    # Bio::EnsEMBL::Utils::Exception::verbose('INFO');

    my $db_path = $self->param_required('db_dir');
    my $idx_dir_al = $db_path . '/uniprot-to-alpha.leveldb';
    my $idx_dir_up = $db_path . '/uniparc-to-uniprot.leveldb';

    # connect to the core database
    my $core_dba = $self->core_dba;
    my $dbc = $core_dba->dbc;

    info(sprintf("Cleaning up old protein features and analysis for species %s\n", $self->param('species')));
    $self->cleanup_protein_features('alphafold_import');

    info(sprintf("Initiating and creating the analysis object for species %s\n", $self->param('species')));

    dblock($db_path);

    my $db = new Tie::LevelDB::DB($idx_dir_al);
    die "Error opening DB with Tie::LevelDB::DB from $idx_dir_al: $!" unless $db;

    my $it = $db->NewIterator;
    $it->SeekToFirst;
    die "DB entry invalid" unless $it->Valid;
    my $alpha_version = (split ',', $it->value)[-1];
    $alpha_version //= 0;

    my $analysis = new Bio::EnsEMBL::Analysis(
            -logic_name    => 'alphafold_import',
            -db            => 'alphafold',
            -db_version    => $alpha_version,
            -db_file       => $self->param('alphafold_db_dir') . '/accession_ids.csv',
            -display_label => 'AlphaFold DB import',
            -displayable   => '1',
            -description   => 'Protein features based on AlphaFold predictions, mapped with GIFTS or UniParc'
    );
    die "Error creating analysis object" unless $analysis;
    my $ana = $core_dba->get_AnalysisAdaptor();
    # We get undef in case of an error. The adaptor does warn, but the error string is not
    # accessible
    $ana->store($analysis) // die "Error storing analysis in DB. Runnable should be restarted";

    # insert the Ensembl-PDB links into the protein_feature table in the core database
    info(sprintf("Calling GIFTS endpoint for species %s using endpoint %s and assembly %s.\n", $self->param('species'), $self->param('rest_server'), $self->param('cs_version')));

    ###  fetch_latest_uniprot_enst_perfect_matches returns data like: { 'A0A0G2K0H5' => [ 'ENSRNOT00000083658' ], 'B5DEL8' => [ 'ENSRNOT00000036389' ], ...}

    my $mappings = eval{fetch_latest_uniprot_enst_perfect_matches($self->param('rest_server'), $self->param('cs_version'))};
    info(sprintf("Done with GIFTS for species %s\n", $self->param('species')));


    my $no_uniparc = 0;
    my $no_uniprot = 0;
    my $protein_count = 0;
    if (! $mappings or ! %$mappings) {

        # If we don't have data in $mappings, this species is not in GIFTS.
        # We'll use the uniparc ids that we have in the core database and map
        # them to the uniprot id and our translation ids (dbid). Then we add the
        # alphafold data using the uniprot id and insert a protein feature using
        # the dbid.

        info(sprintf("No data found for species %s in GIFTS DB using endpoint %s and assembly %s.\n", $self->param('species'), $self->param('rest_server'), $self->param('cs_version')));

        tie(my %uniprot_db, 'Tie::LevelDB', $idx_dir_up)
            or die "Error trying to tie Tie::LevelDB $idx_dir_up: $!";

        # We currently have the same uniparc accession tied to the same
        # translation_id but in different versions (xref pipeline run
        # 'xrefchecksum' and 'uniparc_checksum')
        my $sql = <<SQL;
SELECT xr.dbprimary_acc as uniparc_id, tr.stable_id, tr.translation_id
  FROM xref xr, object_xref ox, translation tr
  where external_db_id = (SELECT external_db_id FROM external_db where db_name = 'UniParc')
    and xr.xref_id = ox.xref_id
    and ox.ensembl_id = tr.translation_id
    group by uniparc_id, tr.stable_id, tr.translation_id
SQL

        my $sth = $dbc->prepare($sql);
        $sth->execute;
        while ( my @row = $sth->fetchrow_array ) {
            $protein_count++;
            my ($uniparc_id, $stable_id, $dbid) = @row;
            my $uniprot_id = $uniprot_db{$uniparc_id};
            unless ($uniprot_id) {
                $no_uniparc++;
                next;
            }
            push @{$mappings->{$uniprot_id}}, {'uniparc' => $uniparc_id, 'dbid' => $dbid, 'ensid' => $stable_id};
        }
        info("Num proteins in DB $protein_count, no uniparc $no_uniparc");

        untie %uniprot_db;

    } else {

        info("Got mapping data from GIFTS");
        # If we have data in $mappings, we got data from GIFTS for this species.
        # Data will look like:
        # $mappings = {uniprot_id ('Q98C34') => ensid ('ENST0000')}
        # We'll use the stable id (ensid) to map to our translation id (dbid). Then we add the
        # alphafold data using the uniprot id and insert a protein feature using
        # the dbid.

        # rev_mappings = (ensid => [uniprot_id, ...])
        my %rev_mappings;
        while (my ($uniprot, $ensid_ref) = each %$mappings) {
            my @ensids = @$ensid_ref;
            for my $ensid (@ensids) {
                push @{$rev_mappings{$ensid}}, $uniprot;
            }
        }

        $mappings = {};

        my $sql = 'select tl.translation_id, tc.stable_id from translation tl, transcript tc
            where tl.transcript_id = tc.transcript_id';

        my $sth = $dbc->prepare($sql);
        $sth->execute;
        while (my @row = $sth->fetchrow_array) {
            my ($dbid, $stable_id) = @row;

            for my $uniprot_id ( @{$rev_mappings{$stable_id}}) {
                unless ($uniprot_id) {
                    $no_uniprot++;
                    next;
                }
                push @{$mappings->{$uniprot_id}}, {'dbid' => $dbid, 'ensid' => $stable_id};
            }
        }
    }

    unless (scalar(keys %$mappings) > 0) {
        die(sprintf("No matches for species %s found in core DB %s\n", $self->param('species'), $dbc->dbname()));
    }

    my $pfa = $core_dba->get_ProteinFeatureAdaptor();

    my $good = 0;
    my $no_alpha = 0;

    info("Unique uniprot accessions for species after mapping: " . scalar (keys %$mappings));
    for my $uniprot (keys %$mappings) {
        for my $entry (@{$mappings->{$uniprot}}) {

            my $uniparc = $entry->{'uniparc'};
            my $ensid = $entry->{'ensid'};
            my $translation_id = $entry->{'dbid'};
            my $alpha_data = $db->Get($uniprot);

            unless ($alpha_data) {
                $no_alpha++;
                next;
            }
            $good++;

            chomp($alpha_data);
            # A0A2I1PIX0 => 1,200,AF-A0A2I1PIX0-F1,4
            my ($al_start, $al_end, $alpha_accession, $alpha_version) = split(",", $alpha_data);

            my $comment = 'Mapped ';
            if ($uniparc) {
                $comment .= "direct from UniParc $uniparc to UniProt $uniprot, Ensembl stable ID $ensid";
            } else {
                $comment .= "using GIFTS DB (UniProt $uniprot, Ensembl stable ID $ensid)";
            }

            info("Protein feature: start $al_start, end $al_end, $alpha_accession: $comment");

            my $pf = Bio::EnsEMBL::ProteinFeature->new(
                    -start    => $al_start,
                    -end      => $al_end,
                    -hseqname => $alpha_accession,
                    -hstart   => $al_start,
                    -hend     => $al_end,
                    -analysis => $analysis,
                    -hdescription => $comment,
            );

            # We get undef in case of an error. The adaptor does warn, but the error string is not
            # accessible
            $pfa->store($pf, $translation_id) // die "Storing protein feature failed. Runnable should be restarted";
        }
    }
    dbunlock();
    info("Inserted $good OK. Num of proteins for species: $protein_count, no uniparc mapping: $no_uniparc, no uniprot mapping: $no_uniprot, no alphafold data: $no_alpha");
}

my $lock_fh;

sub dblock {
    my $path = shift;
    open($lock_fh, ">", "$path/dblock") or die "Failed to create lock file: $!";
    flock ($lock_fh, LOCK_EX) or die "Unable to lock $path/dblock: $!";
}

sub dbunlock {
    flock $lock_fh, LOCK_UN;
    close $lock_fh;
}

sub write_output {
  my $self = shift;
  return 1;
}

# cleans up the protein features from the database 'core_dba'
sub cleanup_protein_features {
    my ($self, $analysis_logic_name) = @_;

    my $core_dba = $self->core_dba;
    my $ana      = $core_dba->get_AnalysisAdaptor();

    my $analysis = $ana->fetch_by_logic_name($analysis_logic_name);

    if (defined($analysis)) {
        my $analysis_id = $analysis->dbID();
        info(sprintf("Found alphafold_import analysis (ID: $analysis_id) for species %s. Deleting it.\n", $self->param('species')));

        my $pfa = $core_dba->get_ProteinFeatureAdaptor();
        $pfa->remove_by_analysis_id($analysis_id);
        $ana->remove($analysis);
    }
}

1;
