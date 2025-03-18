import json
import tarfile

import requests
import os
import urllib.request
import urllib.parse
from tqdm import tqdm
import hashlib

def calculate_md5(filepath):
    """Calculates the MD5 checksum of a file."""
    print(f"Calculating MD5 for {filepath}")
    hasher = hashlib.md5()
    with open(filepath, 'rb') as afile:
        buf = afile.read(8192)
        while len(buf) > 0:
            hasher.update(buf)
            buf = afile.read(8192)
    return hasher.hexdigest()

def verify_downloaded_file(local_filepath, md5_url):
    """Checks if a file is already downloaded and its integrity is valid."""
    print(f"Integrity check for {local_filepath}")
    local_md5_filepath = f"{local_filepath}.md5"

    if not os.path.exists(local_md5_filepath):
        print(f"Downloading MD5 checksum for {md5_url}")
        try:
            urllib.request.urlretrieve(md5_url, local_md5_filepath)

        except urllib.error.URLError as e:
            print(f"Warning: Could not download MD5 checksum for {filename}: {e}")
        except FileNotFoundError:
            print(f"Warning: MD5 checksum file not found for {filename} at {md5_url}")
        except Exception as e:
            print(f"Error processing MD5 checksum for {filename}: {e}")


    if os.path.exists(local_filepath) and os.path.exists(local_md5_filepath):
        try:
            with open(local_md5_filepath, 'r') as md5_file:
                expected_md5 = md5_file.read().strip().split()[0]
            calculated_md5 = calculate_md5(local_filepath)
            if calculated_md5 == expected_md5:
                print(f"File downloaded and integrity check passed: {os.path.basename(local_filepath)}")
                return True
            else:
                print(f"File exists but integrity check failed: {os.path.basename(local_filepath)}")
                os.remove(local_filepath)
                os.remove(local_md5_filepath)
                return False
        except FileNotFoundError:
            return False
        except Exception as e:
            print(f"Error verifying file {os.path.basename(local_filepath)}: {e}")
            return False
    return False

def is_extracted(tar_gz_filepath):
    """Checks if a tar.gz file has already been extracted by looking for a specific file in the same directory."""
    print(f"Check if tar is already extracted: {tar_gz_filepath}")
    base_name_without_gz = os.path.splitext(os.path.basename(tar_gz_filepath))[0] # core_nt.00.tar
    extracted_file_base = os.path.splitext(base_name_without_gz)[0]          # core_nt.00
    extract_dir = os.path.dirname(tar_gz_filepath)                           # /path/to/db/
    expected_extracted_file = os.path.join(extract_dir, extracted_file_base + ".nin")
    return os.path.exists(expected_extracted_file)

def extract_tar_gz(filepath):
    """Extracts a .tar.gz file to the same directory as the file."""
    print(f"Extracting: {filepath}")
    extract_dir = os.path.dirname(filepath)
    try:
        if not os.path.exists(extract_dir):
            os.makedirs(extract_dir)
        with tarfile.open(filepath, 'r:gz') as tar:
            tar.extractall(path=extract_dir)
        print(f"Successfully extracted: {filepath} to {extract_dir}")
        # os.remove(filepath)  # Remove the tar.gz file after extraction
    except tarfile.ReadError as e:
        print(f"Error reading tar.gz file {filepath}: {e}")
    except Exception as e:
        print(f"An error occurred during extraction of {filepath}: {e}")

def download_ncbi_nt_files(json_url, download_dir):
    """
    Downloads files and their MD5 checksums listed in the NCBI metadata JSON,
    and verifies the download integrity. Skips already downloaded and verified files.
    """
    try:
        response = requests.get(json_url)
        response.raise_for_status()
        data = response.json()

        if not os.path.exists(download_dir):
            os.makedirs(download_dir)

        if "files" in data and isinstance(data["files"], list):
            for file_info in data["files"]:
                if isinstance(file_info, dict) and "url" in file_info:
                    file_url = file_info["url"]
                elif isinstance(file_info, str):
                    file_url = file_info
                else:
                    print("Warning: Invalid file_info entry in JSON")
                    continue

                filename = os.path.basename(urllib.parse.urlsplit(file_url).path)
                local_filepath = os.path.join(download_dir, filename)
                md5_url = f"{file_url}.md5"

                if verify_downloaded_file(local_filepath, md5_url):
                    if local_filepath.endswith(".tar.gz"):
                        if is_extracted(local_filepath):
                            print(f"Extraction already verified for: {local_filepath}")
                        else:
                            extract_tar_gz(local_filepath)
                    continue  # Skip further processing if already verified and potentially extracted

                local_md5_filepath = f"{local_filepath}.md5"
                print(f"Downloading: {filename}")

                try:
                    with urllib.request.urlopen(file_url) as response, open(local_filepath, 'wb') as out_file:
                        total_size = int(response.headers.get('content-length', 0))
                        with tqdm(total=total_size, unit='B', unit_scale=True, desc=filename, ncols=80) as pbar:
                            while True:
                                buffer = response.read(8192)
                                if not buffer:
                                    break
                                out_file.write(buffer)
                                pbar.update(len(buffer))

                    print(f"Downloaded: {filename}")
                    # calculated_md5 = calculate_md5(local_filepath)
                    if verify_downloaded_file(local_filepath, md5_url):
                        if local_filepath.endswith(".tar.gz"):
                            extract_tar_gz(local_filepath)

                except urllib.error.URLError as e:
                    print(f"Error downloading {filename}: {e}")
                except Exception as e:
                    print(f"An unexpected error occurred during download of {filename}: {e}")
        else:
            print("Warning: 'files' key not found or is not a list in the JSON.")

    except requests.exceptions.RequestException as e:
        print(f"Error fetching JSON: {e}")
    except json.JSONDecodeError as e:
        print(f"Error decoding JSON: {e}")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

# Example usage:
json_url = "https://ftp.ncbi.nlm.nih.gov/blast/db/core_nt-nucl-metadata.json"
script_directory = os.path.dirname(os.path.abspath(__file__))
download_directory = os.path.join(script_directory, "db")
download_ncbi_nt_files(json_url, download_directory)