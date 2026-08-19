# What is this?

This is a planning document for Claude to setup a new type of workload and trace it using qemu-tracing tool. 

# Key Motivation 

Trace the CPU-side work of a state-of-the-art agentic AI workflow. The key hunch is that these workloads have unique CPU microarchiectural bottlenecks (especially in the processor frontend -- branch prediction unit, instructruction fetch, and decode) than traditional workloads like SPEC CPU. So we want to capture instruction traces from agentic workloads and run them via our simulator of choice, Champsim, to do some rapid design space exploration.

# The Plan

- Boot a VM with one vCPU using QMEU.
- Setup a simple and easy coding agent, SWE-Agent, inside the VM and run it with one task from SWE-Bench-Multi.
    - To capture only the CPU-side of the work (and not the time when agent is waiting on the LLM API to reply back), we want to run SWE-Agent in record-replay mode -- essentially, only capture the CPU work (harness code execution, tool calls, LLM API Proxy etc.).
    - The temparature should be set to zero to have deterministc agentic flow.
- Once the agent is set up, we use our qemu-tracing tool to capture the trace. We need to make sure we capture only the part when the agent is replaying (not during the setup) to get meaningful trace for uarch simulation.
- As the LLM model, we will to use GLM 5.2. Please ask me for the API key when you are setting up the agent.