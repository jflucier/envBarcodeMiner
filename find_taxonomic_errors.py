#!/usr/bin/env python3
"""Find duplicate taxa in FASTA headers that will break DECIPHER"""

import sys
from collections import defaultdict

def find_duplicates(fasta_file):
    # Store: taxon -> {rank -> [parents]}
    taxon_ranks = defaultdict(lambda: defaultdict(set))
    
    with open(fasta_file) as f:
        for line in f:
            if not line.startswith('>'):
                continue
            
            # Parse header
            header = line[1:].strip()
            parts = header.split(';')
            parts = [p.strip() for p in parts if p.strip()]
            
            # Check each taxon in the path
            for i, taxon in enumerate(parts):
                rank = i + 1  # 1=kingdom, 2=phylum, etc.
                parent = parts[i-1] if i > 0 else "Root"
                
                taxon_ranks[taxon][rank].add(parent)
    
    # Find problems
    problems = []
    for taxon, ranks in taxon_ranks.items():
        for rank, parents in ranks.items():
            if len(parents) > 1:
                problems.append((taxon, rank, sorted(parents)))
    
    # Print results
    if not problems:
        print("✓ No duplicate taxa found!")
        return
    
    print(f"✗ Found {len(problems)} problematic taxa:\n")
    
    rank_names = {1: "kingdom", 2: "phylum", 3: "class", 
                  4: "order", 5: "family", 6: "genus"}
    
    for taxon, rank, parents in sorted(problems):
        rank_name = rank_names.get(rank, f"level{rank}")
        print(f"  '{taxon}' at {rank_name} appears under:")
        for parent in parents:
            print(f"    - {parent}")
        print()

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python find_duplicates.py your_file.fasta")
        sys.exit(1)
    
    find_duplicates(sys.argv[1])