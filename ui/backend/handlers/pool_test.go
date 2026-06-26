package handlers

import "testing"

func TestReconcileDecision(t *testing.T) {
	cases := []struct {
		name         string
		clusterExists bool
		state        string
		ready        bool
		opInFlight   bool
		building     bool
		want         PoolAction
	}{
		{"no cluster idle -> build", false, "", false, false, false, ActionBuild},
		{"no cluster but op in flight -> none", false, "", false, true, false, ActionNone},
		{"no cluster but already building -> none", false, "", false, false, true, ActionNone},
		{"warm healthy -> none", true, poolStateWarm, true, false, false, ActionNone},
		{"warm not ready -> rebuild", true, poolStateWarm, false, false, false, ActionRebuild},
		{"warm not ready but op in flight -> none", true, poolStateWarm, false, true, false, ActionNone},
		{"claimed -> none", true, poolStateClaimed, true, false, false, ActionNone},
		{"claimed not ready -> none", true, poolStateClaimed, false, false, false, ActionNone},
		{"unlabeled existing cluster -> none", true, "", true, false, false, ActionNone},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := reconcileDecision(c.clusterExists, c.state, c.ready, c.opInFlight, c.building)
			if got != c.want {
				t.Fatalf("reconcileDecision(%v) = %v, want %v", c.name, got, c.want)
			}
		})
	}
}

func TestClaimDecision(t *testing.T) {
	if claimDecision(true, true) != ClaimStandby {
		t.Fatal("warm+ready should claim standby")
	}
	if claimDecision(true, false) != ClaimLiveBuild {
		t.Fatal("warm-but-not-ready should live build")
	}
	if claimDecision(false, false) != ClaimLiveBuild {
		t.Fatal("no standby should live build")
	}
}
