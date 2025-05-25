# Scripts Directory Overview

This directory contains various scripts for automating tasks, maintenance, and operations related to the Bitrix infrastructure.

Below is a list of scripts and relevant files found in this directory:

*   **`alter-robots-txt.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Modifies the `robots.txt` file, likely to allow or disallow search engine crawlers for development or production environments.
    *   **Notes:** May take arguments to specify the environment (e.g., dev/prod).

*   **`check-404.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Checks for 404 (Not Found) errors on the website, possibly by iterating through a list of URLs.
    *   **Notes:** Might use `urls.txt` or a similar file as input.

*   **`compare-backups.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Compares different backup versions or a backup with the live site to check for differences.

*   **`disaster-recovery.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Automates the process of restoring the website and infrastructure from backups in a disaster scenario.
    *   **Notes:** Likely a critical script that orchestrates multiple recovery steps.

*   **`file-backup.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Performs backups of the website files.

*   **`find-image-type-mismatch.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Scans images to find files whose actual type (e.g., JPEG, PNG) does not match their file extension.

*   **`fix-rights.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Sets the correct file and directory permissions required by the web server (Nginx), PHP, and MySQL containers.
    *   **Notes:** Critical for ensuring the application runs correctly after deployment or file changes.

*   **`mysql-dump.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Creates a dump (backup) of the MySQL database.
    *   **Notes:** May require database credentials, possibly from environment variables or a configuration file.

*   **`optimise-images.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Optimizes image files (e.g., compresses JPEGs and PNGs) to reduce their size and improve website loading times.

*   **`renew-dev.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Refreshes or redeploys the development environment, possibly by pulling latest code and restoring a recent database dump.

*   **`requirements.txt`**
    *   **Type:** Data file (Python dependencies)
    *   **Purpose:** Lists Python package dependencies required by Python scripts in this directory (e.g., `urls.py`).
    *   **Notes:** Used with `pip install -r requirements.txt`.

*   **`setup.py`**
    *   **Type:** Python packaging script (`.py`)
    *   **Purpose:** Standard Python project setup script, likely used for packaging any Python utilities or scripts in this directory if they were to be distributed or installed as a package.

*   **`update-dns-token.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Updates a DNS API token, likely for services like Yandex Cloud DNS used by `dnsrobocert` for SSL certificate renewal.
    *   **Notes:** Requires API credentials, probably sourced from environment variables or a secure configuration file.

*   **`urls.py`**
    *   **Type:** Python script (`.py`)
    *   **Purpose:** Likely contains Python code related to URL processing, generation, or checking, possibly used by `check-404.sh` or other scripts.
    *   **Notes:** May use `requirements.txt` for its dependencies.

*   **`urls.txt`**
    *   **Type:** Data file (Plain text)
    *   **Purpose:** Contains a list of URLs, likely used as input for scripts like `check-404.sh`.
    *   **Notes:** A simple text file with one URL per line.
