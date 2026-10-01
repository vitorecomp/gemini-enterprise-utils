# Gemini Enterprise Utils

A collection of command-line utilities and automation scripts for administering **Google Cloud Gemini Enterprise** (formerly Google Agentspace) via the **Google Cloud Discovery Engine API**.

---

## Repository Structure

```text
gemini-enterprise-utils/
├── LICENSE
├── README.md
└── manage-users/
    └── add-users.sh    # Batch-assign Gemini Enterprise user licenses from a CSV file
```

---

## Prerequisites

1. **Google Cloud SDK (`gcloud`)**: Installed and authenticated.
   ```bash
   # Recommended (exempt from corporate CBA/mTLS restrictions on curl):
   gcloud auth application-default login

   # Or standard user login:
   gcloud auth login
   ```
2. **`curl`**: Installed and available in your `PATH`.
3. **`jq` or `python3`** *(optional)*: Used automatically for pretty-printing JSON payloads and extracting structured API error summaries.
4. **IAM Permissions**: The authenticated Google Cloud principal must have permission to update user licenses in Discovery Engine:
   - `discoveryengine.userStores.batchUpdateUserLicenses` (included in roles such as **Discovery Engine Admin** `roles/discoveryengine.admin`).
   - If omitting `-n <project_number>`, `resourcemanager.projects.get` (e.g., `roles/viewer` or `roles/browser`) is required to resolve the project number automatically from the project ID.

---

## User License Management (`manage-users/add-users.sh`)

[`manage-users/add-users.sh`](manage-users/add-users.sh) reads user email addresses from a CSV file and assigns them a Gemini Enterprise license configuration in batches using the Discovery Engine [`userStores:batchUpdateUserLicenses`](https://cloud.google.com/generative-ai-app-builder/docs/reference/rest/v1alpha/projects.locations.userStores/batchUpdateUserLicenses) endpoint.

### Key Features

- **Pre-flight CSV Validation**: Parses and validates all emails prior to making API calls, automatically skipping header rows (`email`, `userPrincipal`, etc.), blank lines, comments (`#`), malformed emails, and duplicate entries (with line-number warnings).
- **Configurable Batching**: Processes users in batches (default: `10` users per batch) with clear batch progress (`Batch #X/Y`) and per-batch user tracking.
- **Automatic Project Number Resolution**: Accepts `-n <project_number>` explicitly or resolves it automatically from `-p <project_id>` via `gcloud`.
- **Multi-Region Support**: Supports `global` (default) as well as regional locations (`us`, `eu`), routing requests to the appropriate regional Discovery Engine endpoint (`<location>-discoveryengine.googleapis.com`).
- **Verbose Error Diagnostics**: Captures HTTP status codes, parses Google Cloud API error payloads and Long-Running Operation (LRO) statuses, prints actionable troubleshooting hints, logs failed payloads, and outputs a final summary of any failed users.
- **Dry-Run Mode (`-d`)**: Validates the CSV file and previews batch payloads without sending any requests to the API.

### CSV Format

Provide a CSV file with one user email address per line (if the CSV has multiple columns, the first column is used). Header rows such as `email` or `userPrincipal` are automatically ignored:

```csv
email
alice@example.com
bob@example.com
charlie@example.com
```

### Options

| Flag | Required | Default | Description |
| :--- | :---: | :---: | :--- |
| `-f <csv_file>` | Yes | — | Path to the CSV file containing user emails. |
| `-p <project_id>` | Yes | — | Google Cloud Project ID (e.g., `my-gemini-project`). |
| `-i <license_id>` | Yes | — | License Config ID (e.g., `internal_gemini_ent_plus`). |
| `-n <project_number>` | No | Auto-resolved | Google Cloud Project Number (e.g., `584757245252`). Resolved via `gcloud` if omitted. |
| `-a <account>` | No | Active ADC / `gcloud` account | Specific Google Cloud account email to use for authentication (e.g., `admin@gcp.altostrat.com`). |
| `-l <location>` | No | `global` | Discovery Engine location (`global`, `us`, `eu`). |
| `-b <batch_size>` | No | `10` | Number of users to include per batch request. |
| `-v` | No | `false` | Enable verbose debug output (prints request payloads and full API responses). |
| `-d` | No | `false` | Enable dry-run mode (validates CSV and prints batches without calling the API). |
| `-h` | No | — | Display help message and exit. |

### Usage Examples

#### 1. Basic Usage
```bash
chmod +x manage-users/add-users.sh

./manage-users/add-users.sh \
  -f users.csv \
  -p my-gcp-project-id \
  -n 123456789012 \
  -i internal_gemini_ent_plus
```

#### 2. Auto-Resolving Project Number & Verbose Mode
```bash
./manage-users/add-users.sh \
  -f users.csv \
  -p my-gcp-project-id \
  -i internal_gemini_ent_plus \
  -b 20 \
  -v
```

#### 3. Dry-Run Validation (No API Calls)
```bash
./manage-users/add-users.sh \
  -f users.csv \
  -p my-gcp-project-id \
  -n 123456789012 \
  -i internal_gemini_ent_plus \
  -d
```

#### 4. Regional Location (`us` or `eu`)
```bash
./manage-users/add-users.sh \
  -f users.csv \
  -p my-gcp-project-id \
  -n 123456789012 \
  -i internal_gemini_ent_plus \
  -l us
```

---

## Finding Your License Config ID

If you do not know the `LICENSE_ID` (`-i`) for your project, you can list available license configurations in your project using `curl`:

```bash
PROJECT_ID="your-project-id"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
LOCATION="global"

curl -s \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_NUMBER}/locations/${LOCATION}/licenseConfigs"
```

Look for the `name` field in the response:
```json
"name": "projects/123456789012/locations/global/licenseConfigs/<LICENSE_ID>"
```
Pass the `<LICENSE_ID>` segment to `-i`.

---

## Troubleshooting Common Errors

- **HTTP 400 (`INVALID_ARGUMENT` / `FAILED_PRECONDITION`)**:
  - The specified `-i <license_id>` does not exist under `projects/<project_number>/locations/<location>/licenseConfigs/<license_id>`.
  - Your subscription has reached its maximum seat capacity for that license configuration.
- **HTTP 401 (`UNAUTHENTICATED` / `ACCESS_TOKEN_TYPE_UNSUPPORTED`)**:
  - **Domain Policy / CBA Restriction (`The account was restricted due to a domain admin's policies`)**: Corporate accounts (such as `@google.com`) enforce Certificate-Based Access (CBA/mTLS) on tokens minted via `gcloud auth print-access-token`, which causes `curl` requests to fail with `ACCESS_TOKEN_TYPE_UNSUPPORTED`. Fix this by authenticating with Application Default Credentials (ADC), which the script automatically prefers when available:
    ```bash
    gcloud auth application-default login
    ```
  - **Cross-Domain / Secondary Account**: If the target project belongs to a different organization/domain (for example, `@gcp.altostrat.com`), log in with that account (`gcloud auth login your-user@gcp.altostrat.com`) and pass `-a your-user@gcp.altostrat.com`.
- **HTTP 403 (`PERMISSION_DENIED`)**:
  - Your account lacks `discoveryengine.userStores.batchUpdateUserLicenses` on the target project, or the Discovery Engine API is not enabled.
- **HTTP 404 (`NOT_FOUND`)**:
  - Verify that the project ID (`-p`), project number (`-n`), and location (`-l`, e.g., `global`, `us`, `eu`) match where your Gemini Enterprise user store is provisioned.

---

## License

This project is licensed under the [MIT License](LICENSE).