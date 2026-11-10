//! Pipe tables, as GitHub writes them.
//!
//! A table block keeps its lines as written (see
//! [`BlockKind::Table`](crate::BlockKind::Table)); this module reads them
//! as cells for an editor to show, and writes cells back as lines.

/// How a column's cells are set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Align {
    #[default]
    None,
    Left,
    Center,
    Right,
}

/// A table's cells. Each cell is inline Markdown.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Table {
    pub header: Vec<String>,
    pub alignments: Vec<Align>,
    pub rows: Vec<Vec<String>>,
}

/// Whether a line is the row of dashes under a table's header: `|---|:-:|`.
pub fn is_separator(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with('|') && trimmed.contains('-') && trimmed.chars().all(|c| matches!(c, '|' | '-' | ':' | ' '))
}

impl Table {
    /// Reads a table block's text. `None` when it is not a header line
    /// with a separator under it.
    pub fn parse(text: &str) -> Option<Table> {
        let mut lines = text.lines();
        let header = cells(lines.next()?);
        let separator = lines.next().filter(|l| is_separator(l))?;
        let alignments = cells(separator)
            .iter()
            .map(|cell| match (cell.starts_with(':'), cell.ends_with(':')) {
                (true, true) => Align::Center,
                (true, false) => Align::Left,
                (false, true) => Align::Right,
                (false, false) => Align::None,
            })
            .collect();
        let rows = lines.take_while(|l| l.trim_start().starts_with('|')).map(cells).collect();
        Some(Table { header, alignments, rows })
    }

    /// The table as lines of Markdown, a row a line, no line break at the
    /// end: what a table block's text is set to.
    pub fn to_markdown(&self) -> String {
        let row = |cells: &[String]| {
            let escaped: Vec<String> = cells.iter().map(|c| c.replace('|', "\\|")).collect();
            format!("| {} |", escaped.join(" | "))
        };
        let separator: Vec<String> = (0..self.header.len())
            .map(|i| match self.alignments.get(i).copied().unwrap_or_default() {
                Align::None => "---",
                Align::Left => ":--",
                Align::Center => ":-:",
                Align::Right => "--:",
            })
            .map(str::to_owned)
            .collect();
        let mut lines = vec![row(&self.header), format!("| {} |", separator.join(" | "))];
        lines.extend(self.rows.iter().map(|r| row(r)));
        lines.join("\n")
    }
}

/// A row's cells: split at each `|` not escaped, with `\|` unescaped.
fn cells(line: &str) -> Vec<String> {
    let mut body = line.trim();
    body = body.strip_prefix('|').unwrap_or(body);
    if body.ends_with('|') && !body.ends_with("\\|") {
        body = &body[..body.len() - 1];
    }
    let mut cells = Vec::new();
    let mut current = String::new();
    let mut chars = body.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                chars.next();
                current.push('|');
            }
            '|' => cells.push(std::mem::take(&mut current).trim().to_owned()),
            c => current.push(c),
        }
    }
    cells.push(current.trim().to_owned());
    cells
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_cells_alignments_and_escaped_pipes() {
        let table = Table::parse("| Name | Born | Note |\n|:-----|-----:|:----:|\n| Ada | 1815 | a \\| b |\n| Grace | 1906 |\n").unwrap();
        assert_eq!(table.header, ["Name", "Born", "Note"]);
        assert_eq!(table.alignments, [Align::Left, Align::Right, Align::Center]);
        assert_eq!(table.rows, [vec!["Ada", "1815", "a | b"], vec!["Grace", "1906"]]);
        assert_eq!(Table::parse("| not a table |\njust text"), None);
        assert!(is_separator("|---|---|"));
        assert!(!is_separator("| a | b |"));
        assert!(!is_separator("---"));
    }

    #[test]
    fn writes_back_what_reads_the_same() {
        let table = Table::parse("|a|b|\n|-|:-:|\n|1|x \\| y|").unwrap();
        let written = table.to_markdown();
        assert_eq!(written, "| a | b |\n| --- | :-: |\n| 1 | x \\| y |");
        assert_eq!(Table::parse(&written).unwrap(), table);
    }
}
