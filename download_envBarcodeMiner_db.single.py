import json
import requests
import os
import urllib.request
import urllib.parse
from tqdm import tqdm

def download_ncbi_nt_files(json_url, download_dir):
    """
    Downloads files listed in the NCBI nt-nucl-metadata.json file with progress bar.
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

                except Exception as e:
                    print(f"Error downloading {filename}: {e}")

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