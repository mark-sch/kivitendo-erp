# @tag: acc_trans_id_uniqueness
# @description: Sorgt dafür, dass acc_trans.acc_trans_id eindeutig ist
# @depends: release_2_6_1
# @charset: utf-8

use utf8;
use strict;
use Data::Dumper;

die "This script cannot be run from the command line." unless $::form;

sub mydberror {
  my ($msg) = @_;
  die $dbup_locale->text("Database update error:") . "<br>$msg<br>" . $DBI::errstr;
}

sub do_query {
  my ($query, $may_fail) = @_;

  return if $dbh->do($query);

  mydberror($query) unless ($may_fail);
  $dbh->rollback();
  $dbh->begin_work();
}

sub do_update {
  my $query = <<SQL;
    SELECT acc_trans_id, trans_id, itime, mtime
    FROM acc_trans
    WHERE acc_trans_id IN (
      SELECT acc_trans_id FROM acc_trans GROUP BY acc_trans_id HAVING COUNT(*) > 1
    )
    ORDER BY trans_id, itime, mtime NULLS FIRST
SQL

  my @entries = selectall_hashref_query($form, $dbh, $query);

  return 1 unless @entries;

  $query = <<SQL;
    SELECT setval('acc_trans_id_seq', (
      SELECT COALESCE(MAX(acc_trans_id), 0) + 1
      FROM acc_trans
    ))
SQL

  do_query($query, 0);

  my %entries_by_trans_id;
  foreach my $entry (@entries) {
    if (!$entries_by_trans_id{ $entry->{trans_id} }) {
      $entries_by_trans_id{ $entry->{trans_id} } = [];
    } else {
      my $mtime = $entry->{mtime} ? "= '$entry->{mtime}'" : 'IS NULL';
      $query    = <<SQL;
        UPDATE acc_trans
        SET acc_trans_id = nextval('acc_trans_id_seq')
        WHERE (acc_trans_id = $entry->{acc_trans_id})
          AND (trans_id     = $entry->{trans_id})
          AND (itime        = '$entry->{itime}')
          AND (mtime $mtime)
SQL

      do_query($query, 0);
    }
  }

  return 1;
}

return do_update();
