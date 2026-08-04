# ADR-0002: Manual Git LFS Implementation

## Status

Accepted

## Context

The application requires Git Large File Storage (LFS) support to efficiently handle binary files in repositories. However, libgit2 (as documented in ADR-0001) does not include native Git LFS support.

Options considered:
1. **Use a separate LFS library**: Add another dependency specifically for LFS operations
2. **Manual LFS implementation**: Implement the LFS protocol manually using direct HTTP operations and pointer file generation
3. **Avoid LFS entirely**: Not feasible given project requirements for handling large binary files

## Decision

We will manually implement Git LFS support by:
- Manually pushing binary objects directly to the Git LFS server via HTTP
- Manually building LFS pointer files and adding them to the Git repository through libgit2

## Consequences

### Positive
- Full control over LFS operations and error handling
- No additional third-party dependencies
- Can optimize the implementation for our specific use case
- Better understanding of the LFS protocol
- Flexibility to implement only the LFS features we need

### Negative
- Requires implementing and maintaining LFS protocol logic
- Need to handle HTTP operations for LFS server communication
- Must manually construct LFS pointer files according to specification
- Responsible for implementing LFS authentication and error handling
- Additional testing burden for LFS-specific functionality

### Implementation Notes
- LFS pointer files follow the format specified in Git LFS specification
- Binary objects are uploaded to LFS server using HTTP PUT/POST
- Pointer files contain: version, oid (SHA-256), and size fields
- LFS server endpoints follow the Git LFS API specification

