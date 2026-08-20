package handlers

import (
	"strings"
	"testing"
	"time"
)

func TestFinishDoneLogsElapsedTime(t *testing.T) {
	d := &deployManager{state: "idle"}
	d.resetForNewRun()
	time.Sleep(10 * time.Millisecond)
	d.finish("done")

	if len(d.logs) == 0 {
		t.Fatalf("expected at least one log entry, got none")
	}
	last := d.logs[len(d.logs)-1]
	if !strings.Contains(last.Message, "Total time") {
		t.Errorf("expected final log to report elapsed time, got %q", last.Message)
	}
}

func TestFinishFailedDoesNotLogElapsedTime(t *testing.T) {
	d := &deployManager{state: "idle"}
	d.resetForNewRun()
	d.addLog("error", "boom")
	d.finish("failed")

	last := d.logs[len(d.logs)-1]
	if strings.Contains(last.Message, "Total time") {
		t.Errorf("did not expect elapsed time log on failure, got %q", last.Message)
	}
}
