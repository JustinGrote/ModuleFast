# Testing
- Run `Invoke-Build Test` for tests. To run an individual test, run `Invoke-Build Test -TestName <test name>`.
- To run ModuleFast directly, use `Start-Job -ScriptBlock { Import-Module .\modulefast.psm1; <Your test code here> } | Receive-Job -Wait -AutoRemoveJob` to avoid module locking issues.