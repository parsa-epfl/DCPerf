import re
import sys
import argparse
import pandas as pd
import matplotlib.pyplot as plt
from datetime import timedelta
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Image, Spacer, Table, TableStyle
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet


# ---------------------------
# Parse mpstat.log format
# ---------------------------
def parse_mpstat_log(filename):

    # Pattern for 12-hour timestamps with AM/PM
    pattern_12 = re.compile(
        r"(\d{2}:\d{2}:\d{2}\s+[AP]M)\s+all\s+"
        r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+"
        r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)"
    )

    # Pattern for 24-hour timestamps
    pattern_24 = re.compile(
        r"(\d{2}:\d{2}:\d{2})\s+all\s+"
        r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+"
        r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)"
    )

    # Determine format by scanning first valid timestamp
    chosen_pattern = None
    timestamp_format = None

    with open(filename, "r") as f:
        for line in f:
            if pattern_12.search(line):
                chosen_pattern = pattern_12
                timestamp_format = "%I:%M:%S %p"
                break
            if pattern_24.search(line):
                chosen_pattern = pattern_24
                timestamp_format = "%H:%M:%S"
                break
        if chosen_pattern is None:
            raise ValueError("No valid mpstat timestamp found in file.")

    records = []
    with open(filename, "r") as f:
        for line in f:
            m = chosen_pattern.search(line)
            if m:
                timestamp = m.group(1)
                values = list(map(float, m.groups()[1:]))
                records.append([timestamp] + values)

    columns = [
        "timestamp", "%usr", "%nice", "%sys", "%iowait",
        "%irq", "%soft", "%steal", "%guest", "%gnice", "%idle"
    ]

    df = pd.DataFrame(records, columns=columns)
    df["timestamp"] = pd.to_datetime(df["timestamp"], format=timestamp_format)

    # ✅ Compute elapsed seconds since first sample
    df["elapsed_s"] = (df["timestamp"] - df["timestamp"].iloc[0]).dt.total_seconds()

    return df



# ---------------------------
# Filter last X seconds if needed
# ---------------------------
def filter_last_x_seconds(df, seconds):
    if seconds is None:
        return df
    end_time = df["timestamp"].max()
    start_time = end_time - timedelta(seconds=seconds)
    return df[df["timestamp"] >= start_time]


# ---------------------------
# Plotting helper
# ---------------------------
def add_plot(elements, df, cols, title, filename):
    plt.figure(figsize=(10, 4))
    for c in cols:
        plt.plot(df["elapsed_s"], df[c], label=c)
    plt.legend()
    plt.title(title)
    plt.xlabel("Elapsed Time (s)")
    plt.ylabel("Percentage")
    plt.grid(True)
    plt.tight_layout()
    plt.savefig(filename)
    plt.close()

    elements.append(Image(filename, width=500, height=200))
    elements.append(Spacer(1, 12))


# ---------------------------
# Table of summary statistics
# ---------------------------
def summary_table(df):
    cols = ["%sys", "%usr", "%idle", "%iowait", "%irq", "%nice", "%soft", "%steal", "%gnice", "%guest"]
    stats = df[cols].agg(["mean", "max", "min"]).T.reset_index()
    stats.columns = ["Metric", "Mean", "Max", "Min"]
    return stats


# ---------------------------
# Create PDF Report
# ---------------------------
def generate_pdf(df, output_pdf, subset_seconds=None):
    styles = getSampleStyleSheet()
    elements = []

    title = "MPStat Performance Report"
    elements.append(Paragraph(title, styles["Title"]))
    elements.append(Spacer(1, 12))

    if subset_seconds:
        elements.append(Paragraph(f"Filtered for last {subset_seconds} seconds", styles["Normal"]))
        elements.append(Spacer(1, 12))

    # Main plots
    add_plot(elements, df, ["%sys", "%usr", "%idle"], "System/User/Idle CPU Usage", "plot_sys_usr_idle.png")
    add_plot(elements, df, ["%iowait", "%irq", "%nice", "%soft", "%steal", "%gnice", "%guest"],
             "Detailed CPU Metrics", "plot_detailed.png")

    # Summary statistics table
    stats = summary_table(df)
    data = [stats.columns.tolist()] + stats.values.tolist()
    table = Table(data)
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.grey),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.whitesmoke),
        ("ALIGN", (0, 0), (-1, -1), "CENTER"),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("BOTTOMPADDING", (0, 0), (-1, 0), 12),
        ("GRID", (0, 0), (-1, -1), 1, colors.black)
    ]))
    elements.append(Paragraph("Summary Statistics", styles["Heading2"]))
    elements.append(table)

    doc = SimpleDocTemplate(output_pdf, pagesize=letter)
    doc.build(elements)


# ---------------------------
# Main
# ---------------------------
def main():
    parser = argparse.ArgumentParser(description="Generate PDF report from mpstat.log")
    parser.add_argument("filename", help="mpstat log file")
    parser.add_argument("--last", type=int, help="Analyze only the last X seconds")
    parser.add_argument("--out", default="mpstat_report.pdf", help="Output PDF file name")
    args = parser.parse_args()

    df = parse_mpstat_log(args.filename)

    # Full dataset
    generate_pdf(df, args.out.replace(".pdf", "_full.pdf"))

    # Last X seconds subset (optional)
    if args.last:
        subset_df = filter_last_x_seconds(df, args.last)
        generate_pdf(subset_df, args.out.replace(".pdf", f"_last{args.last}.pdf"), subset_seconds=args.last)

    print(f"✅ Reports generated successfully: {args.out.replace('.pdf', '_full.pdf')}", end="")
    if args.last:
        print(f" and {args.out.replace('.pdf', f'_last{args.last}.pdf')}")
    else:
        print("")


if __name__ == "__main__":
    main()
