import json
import requests
import os
import urllib.request
import urllib.parse
from tqdm import tqdm
import threading
import queue
from concurrent.futures import ThreadPoolExecutor

def download_file(file_url, local_filepath, q, pbar_lock, pbar):
    """Downloads a single file and updates the shared progress bar."""
    filename = os.path.basename(urllib.parse.urlsplit(file_url).path)
    try:
        with urllib.request.urlopen(file_url) as response, open(local_filepath, 'wb') as out_file:
            while True:
                buffer = response.read(8192)
                if not buffer:
                    break
                out_file.write(buffer)
                with pbar_lock:
                    pbar.update(len(buffer))

        q.put(f"Downloaded: {filename}")
    except Exception as e:
        q.put(f"Error downloading {filename}: {e}")

def download_ncbi_nt_files(json_url, download_dir, max_concurrent=4):
    """Downloads files listed in the NCBI nt-nucl-metadata.json file with multithreading and a single progress bar, limited to max_concurrent."""
    try:
        response = requests.get(json_url)
        response.raise_for_status()
        data = response.json()

        if not os.path.exists(download_dir):
            os.makedirs(download_dir)

        if "files" in data and isinstance(data["files"], list):
            print("Preparing for NCBI NT download. This might take some time...")
            file_urls = []
            total_size = 0
            file_size_counter = 0
            total_files = len(data["files"])
            for file_info in data["files"]:
                file_size_counter += 1
                print(f"{file_size_counter}/{total_files}: fetching size of {file_info}")
                if isinstance(file_info, dict) and "url" in file_info:
                    file_url = file_info["url"]
                elif isinstance(file_info, str):
                    file_url = file_info
                else:
                    print("Warning: Invalid file_info entry in JSON")
                    continue
                filename = os.path.basename(urllib.parse.urlsplit(file_url).path)
                local_filepath = os.path.join(download_dir, filename)
                file_urls.append((file_url, local_filepath))

                try:
                    with urllib.request.urlopen(file_url) as test_response:
                        total_size += int(test_response.headers.get('content-length', 0))
                except:
                    print(f"Warning: Could not get content length for {filename}")

            q = queue.Queue()
            pbar_lock = threading.Lock()
            pbar = tqdm(total=total_size, unit='B', unit_scale=True, desc="Total Progress", ncols=80)

            with ThreadPoolExecutor(max_workers=max_concurrent) as executor:
                futures = []
                for file_url, local_filepath in file_urls:
                    future = executor.submit(download_file, file_url, local_filepath, q, pbar_lock, pbar)
                    futures.append(future)

                for future in futures:
                    future.result() # Wait for each future to complete.

            pbar.close()
            while not q.empty():
                print(q.get())

        else:
            print("Warning: 'files' key not found or is not a list in the JSON.")

    except requests.exceptions.RequestException as e:
        print(f"Error fetching JSON: {e}")
    except json.JSONDecodeError as e:
        print(f"Error decoding JSON: {e}")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

# Example usage:
json_url = "https://ftp.ncbi.nlm.nih.gov/blast/db/nt-nucl-metadata.json"
script_directory = os.path.dirname(os.path.abspath(__file__))
download_directory = os.path.join(script_directory, "database")
download_ncbi_nt_files(json_url, download_directory, max_concurrent=4)
