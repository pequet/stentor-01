# Pre-Flight

This checklist outlines essential steps to ensure the project template is clean, organized, and ready for a new iteration or for users starting a new project based on it.

## 1. Process and Integrate Derived AI Rules

*   **Objective:** Ensure that valuable, project-specific AI guidance discovered during development is properly organized and non-redundant.
*   **Actions:**
    - [ ] Review the `derived-cursor-rules.mdc` file (located in `.cursor/rules/derived-cursor-rules.mdc`).
    - [ ] Identify any new, useful, or refined rules that have been auto-generated by SpecStory.
    - [ ] **Migrate Rules:** Move these rules into new or existing dedicated `.mdc` files within the `.cursor/rules/` directory. Follow the naming conventions outlined in `000-rule-organization.mdc`.
    - [ ] **Ensure Non-Redundancy:** Verify that the migrated rules do not duplicate information already present in other rule files, adhering to `270-avoid-redundancy.mdc`.
    - [ ] Once processed and migrated, **clear the contents** of `.cursor/rules/derived-cursor-rules.mdc` to provide a clean slate for the next development cycle. It should ideally only contain its standard boilerplate/warning after this step.

## 2. Clean AI Interaction History

*   **Objective:** Reset AI interaction context to provide a fresh start for the template user or the next development cycle.
*   **Actions:**
    - [ ] **Clear Cursor Chat History:** Manually delete the AI chat history within the Cursor IDE for this project.
    - [ ] **Clear SpecStory History:** Delete the contents of the `.specstory/history/` directory. This removes the raw chat logs saved by SpecStory.
    - [ ] **(Optional) Clear SpecStory AI Rules Backups:** Delete the contents of the `.specstory/ai_rules_backups/` directory if you want to remove backups of previous `derived-cursor-rules.mdc` versions.

## 3. Review Memory Bank

*   **Objective:** Ensure the Memory Bank reflects the latest stable state of the template, not transient development states.
*   **Actions:**
    - [ ] Review `memory-bank/active-context.md` and clear any session-specific notes that are not relevant for a template user.
    - [ ] Ensure `memory-bank/development-status.md` accurately reflects the template's features.
    - [ ] Check `memory-bank/development-log.md` for any entries that should be summarized or archived if they relate to the *development of the template itself* rather than guidance for *using the template*.

## 4. Final Sanity Checks

*   **Objective:** Catch any lingering issues.
*   **Actions:**
    - [ ] Ensure all placeholder values or template-specific examples are clearly marked for user modification or removal.
    - [ ] Verify that the project builds/runs if it's an executable template.
    - [ ] Briefly review the `README.md` for clarity and accuracy.

### 📋 Release Readiness

- [ ] **Documentation Reviewed**: All relevant documentation (`README.md`, `docs/`, Memory Bank files) has been reviewed and updated for accuracy and completeness.
- [ ] **Changelog Updated**: `CHANGELOG.md` accurately reflects all notable changes for the upcoming release and follows semantic versioning.
- [ ] **Functionality Verified**: All core features and critical paths of the application have been tested and are working as expected.
- [ ] **Dependencies Checked**: All project dependencies are up-to-date and have no known critical vulnerabilities.
- [ ] **Configuration Finalized**: All necessary configuration for the release (environment variables, service settings) is in place and validated.

By following this checklist, you help maintain the quality and usability of the project template. 