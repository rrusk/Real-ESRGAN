#!/usr/bin/env python3
"""
Script Name: convert_chapters.py
Description: Converts raw 'Title Timestamp' text files into OGM format for MKVToolNix.
Usage: python convert_chapters.py input.txt -o chapters.txt
"""

import argparse
import logging
import re
import sys
from pathlib import Path
from typing import List, Tuple, Optional

# 1. Configure Logging (Best Practice: Structure output, don't just print)
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s"
)
logger = logging.getLogger(__name__)

def parse_raw_chapters(content: str) -> str:
    """
    Parses raw text content and returns OGM formatted string.
    Handles irregularities like split lines and source tags.
    """
    lines = content.split('\n')
    chapters: List[Tuple[str, str]] = []
    current_title_buffer: Optional[str] = None

    # Regex: Matches "mm:ss" or "m:ss" at the end of a line ($)
    time_pattern = re.compile(r'(\d{1,2}):(\d{2})$')

    for line in lines:
        line = line.strip()
        if not line: 
            continue

        # Clean artifacts (e.g. "")
        line = re.sub(r'^\\s*', '', line)

        match = time_pattern.search(line)
        
        if match:
            minutes = int(match.group(1))
            seconds = int(match.group(2))
            
            # Format to HH:MM:SS.000
            timestamp_str = f"00:{minutes:02}:{seconds:02}.000"

            # Extract title (everything before the timestamp)
            title_part = line[:match.start()].strip()

            if not title_part and current_title_buffer:
                # Edge Case: Line has time but no title (e.g., "Coca Rola")
                chapters.append((current_title_buffer, timestamp_str))
                current_title_buffer = None
            else:
                # Standard Case: Line has both title and time
                chapters.append((title_part, timestamp_str))
        else:
            # No timestamp found; buffer this line as the title for the next line
            current_title_buffer = line

    # Generate Output
    output_lines = []
    for i, (name, time) in enumerate(chapters, 1):
        output_lines.append(f"CHAPTER{i:02}={time}")
        output_lines.append(f"CHAPTER{i:02}NAME={name}")

    return "\n".join(output_lines)

def main():
    # 2. Argument Parsing
    parser = argparse.ArgumentParser(
        description="Convert raw chapter text (Title MM:SS) to OGM format for mkvmerge.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Input File Format Requirements:
  The script expects a text file where each line ends with a timestamp 
  in 'M:SS' or 'MM:SS' format.

  Example Input:
    Introduction 0:00
    The Big Reveal 12:45
    Final Credits 1:02:30

  Note: The script expects the timestamp (m:ss or mm:ss) at the end
  of each line. If a title is on one line and the timestamp is on the next,
  the script will attempt to buffer them together.
"""
    )
    parser.add_argument(
        "input_file", 
        type=Path, 
        help="Path to the raw text file (e.g., source.txt)"
    )
    parser.add_argument(
        "-o", "--output", 
        type=Path, 
        default=Path("chapters.txt"), 
        help="Path to the output OGM file (default: chapters.txt)"
    )

    args = parser.parse_args()

    # 3. Validation and Execution
    if not args.input_file.exists():
        logger.error(f"Input file not found: {args.input_file}")
        sys.exit(1)

    try:
        # Reading with UTF-8 to handle special characters (best practice)
        content = args.input_file.read_text(encoding="utf-8")
        
        logger.info(f"Parsing {args.input_file}...")
        ogm_content = parse_raw_chapters(content)
        
        if not ogm_content:
            logger.warning("No chapters were found/parsed.")
            sys.exit(1)

        args.output.write_text(ogm_content, encoding="utf-8")
        logger.info(f"Successfully wrote {args.output}")

    except Exception as e:
        logger.exception(f"An unexpected error occurred: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
