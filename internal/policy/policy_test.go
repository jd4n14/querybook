package policy

import "testing"

func TestConservativeBypassMatrix(t *testing.T) {
	denied := []string{"-- x\nDELETE FROM t", "WITH x AS (SELECT 1) DELETE FROM t", "EXPLAIN DELETE FROM t", "PRAGMA journal_mode=WAL", "VACUUM", "SELECT 1; DELETE FROM t", "SELECT 'unterminated", "SELECT 'x' INTO OUTFILE '/tmp/x'", "SELECT * FROM t FOR UPDATE", "SELECT * FROM t LOCK IN SHARE MODE"}
	for _, sql := range denied {
		if d := Classify(sql); d.Allowed {
			t.Errorf("allowed unsafe SQL %q", sql)
		}
	}
	for _, sql := range []string{"select 1", "SHOW TABLES;", "/* comment */ describe t", "EXPLAIN SELECT 1", "SELECT ';'"} {
		if d := Classify(sql); !d.Allowed {
			t.Errorf("denied read %q: %s", sql, d.Reason)
		}
	}
}
