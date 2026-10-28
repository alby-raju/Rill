# Wiki publishing

These Markdown sources are the reviewed onboarding pages for the GitHub Wiki. Keep implementation details and the full task list in the existing versioned docs; Wiki pages link to them.

GitHub must initialize the Wiki by saving its first Home page through the signed-in repository UI. The Wiki has its own Git repository and does not accept main-repository pull requests. After initialization, clone `https://github.com/alby-raju/Rill.wiki.git`, inspect its current pages, and copy the named pages from this directory (excluding this README) into that checkout. Review the diff and commit/push normally without force. Preserve unrelated existing pages.

Publish only after the source documentation PR merges. After pushing, verify Home, navigation, CLI, mocks and roadmap links on GitHub. Future changes should be reviewed in the main repository before mirroring them to the Wiki.
