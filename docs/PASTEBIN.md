# The Pastebin mirror

When the web site cannot be reached, Tessera can be installed from Pastebin: every package file, every package document and the signed registry index are separate public pastes,
and a *snapshot* paste says which is which. Files that are too long for one paste are split over several (and binary files are stored as base64); the installer and the package
manager put them back together and check the SHA-256 of every file, and the registry index must carry the project's signature, so a changed paste is refused.

*The mirror has not been published yet.*
