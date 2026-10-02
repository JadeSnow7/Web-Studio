# Session interruptions and rejected batches

- output-matrix-01: rejected; initial UI/App correspondence not independently established. See output-matrix-01-rejected.json.
- output-matrix-02: setup expired after 60 seconds. GUI call returned after an anomalously long tool wait (reported 9082 seconds); late ready.json is not evidence the failed coordinator measured anything.
- output-matrix-03: VT ASCII child ancestry matched sampled App (83401 -> 82013). Legacy setup timed out; no complete comparison pair. Record also reports revision_changed because profile tooling changed during this batch.
- Main discovered that calling App.getAXState after Cmd-Q can select/relaunch the just-quit App. Post-quit observation switched to inventory-only. Newly relaunched isolated PID 94993 was terminated only after checking its exact owned executable path. Original GUI PID 21524 remained running.
- These are orchestration/tool failures, not terminal performance regressions. Preserve all original records. No accepted six-pair baseline yet.
