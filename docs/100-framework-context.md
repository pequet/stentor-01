# 100: Framework Context

> [!NOTE]
> This document originates from a boilerplate template which may have evolved since this project was created. The latest version can be found in the [cursor-project-boilerplate repository](https://github.com/pequet/cursor-project-boilerplate/blob/main/docs/000-Framework-Context.md).

This public repository, while fully functional on its own, is designed to serve as a **submodule** within a larger, homegrown and highly opinionated private framework for integrated thinking. This document is thus a "convex mirror" looking out from the repository into the framework that gives it context.

For a standalone user, this information is optional. For the developer concerned with the recursivesystem-level context, it is crucial.

## The Surrounding `Curiosities Cabinet` Project Structure

This public repository (`stentor-01/`) does not exist in a vacuum. It is a `View` inside a parent `Curiosities Cabinet` project that has the standard structure:

```text
Projects/
└── Curiosities Cabinet/
    ├── Controllers/
    ├── Models/
    │   ├── 0. Inbox/
    │   ├── 1. Projects/
    │   ├── 2. Knowledge/
    │   ├── 3. Resources/
    │   └── 4. Archives/
    └── Views/
        └── Public Repositories/
            ├── Stentor
            │   └── stentor-01 # This Public Repo
```

## Why This Structure Exists

The parent framework is built on a specific development methodology:

MVC:

-   **Models:** The `Models` folder contains the data and logic for the project.
-   **Views:** The `Views` folder contains the user interface for the project.
-   **Controllers:** The `Controllers` folder contains the logic for the project.

PARA:

-   **Projects:** The `Projects` folder contains the projects for the project.
-   **Areas/Knowledge:** The `Knowledge` folder contains the knowledge for the project.
-   **Resources:** The `Resources` folder contains the resources for the project.
-   **Archives:** The `Archives` folder contains the archives for the project.

Principles:

-   **Inbox-Driven Development:** All new ideas, notes, tasks, and raw information related to this project are captured in the parent `Models/0. Inbox/`. This keeps the public repository clean while ensuring no idea is lost.
-   **Archival Over Deletion:** With the "never delete" principle, instead of deleting files, they are moved to the parent `Models/4. Archives/`. This preserves project history and context.
-   **Private Asset Management:** The sibling `private/` directory is used to store development artifacts (`.cursor/`, `.specstory/`, `memory-bank/`) that are essential for development, should be versioned in the private parent repository, but should not generally be part of the public history.

This structure allows us to maintain a clean, professional public repository while leveraging a powerful private backend for development, versioning, and knowledge management. 
