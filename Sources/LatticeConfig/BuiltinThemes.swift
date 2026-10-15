/// Built-in themes, written in the same YAML format as user themes (`~/.config/lattice/themes/NAME.yaml`),
/// so they double as examples. A user file with the same name wins.
public enum BuiltinThemes {
    public static let all: [String: String] = [
        "lattice": lattice, "nord": nord, "gruvbox": gruvbox, "catppuccin": catppuccin,
    ]

    public static let lattice = """
        # Lattice — neutral, follows macOS light/dark.
        font-size: 13
        radius: 10
        border-width: 3
        border-radius: 12
        opacity: 0.94
        dark:
          background: "#1c1c1f"
          surface: "#2e2e33"
          foreground: "#ececf1"
          muted: "#9a9aa3"
          accent: "#5b9cff"
          urgent: "#ff5f57"
          border: "#5b9cff"
        light:
          background: "#f6f6f8"
          surface: "#e3e3e8"
          foreground: "#1c1c1f"
          muted: "#6b6b74"
          accent: "#0a64e0"
          urgent: "#d70015"
          border: "#0a64e0"
        """

    public static let nord = """
        # Nord — arcticicestudio/nord palette (dark only).
        radius: 8
        border-width: 3
        border-radius: 12
        dark:
          background: "#2e3440"
          surface: "#3b4252"
          foreground: "#eceff4"
          muted: "#a3acbd"
          accent: "#88c0d0"
          urgent: "#bf616a"
          border: "#88c0d0"
        """

    public static let gruvbox = """
        # Gruvbox — morhetz/gruvbox, dark + light.
        radius: 6
        border-width: 3
        border-radius: 10
        dark:
          background: "#282828"
          surface: "#3c3836"
          foreground: "#ebdbb2"
          muted: "#a89984"
          accent: "#fabd2f"
          urgent: "#fb4934"
          border: "#fabd2f"
        light:
          background: "#fbf1c7"
          surface: "#ebdbb2"
          foreground: "#3c3836"
          muted: "#7c6f64"
          accent: "#b57614"
          urgent: "#9d0006"
          border: "#b57614"
        """

    public static let catppuccin = """
        # Catppuccin — Mocha (dark) / Latte (light).
        radius: 12
        border-width: 3
        border-radius: 12
        dark:
          background: "#1e1e2e"
          surface: "#313244"
          foreground: "#cdd6f4"
          muted: "#a6adc8"
          accent: "#cba6f7"
          urgent: "#f38ba8"
          border: "#cba6f7"
        light:
          background: "#eff1f5"
          surface: "#ccd0da"
          foreground: "#4c4f69"
          muted: "#6c6f85"
          accent: "#8839ef"
          urgent: "#d20f39"
          border: "#8839ef"
        """
}
