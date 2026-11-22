class Theme {
    public string Name, Bg, Card, Text, Sub, Accent, Accent2, OnAccent, Track, Glyphs, Font, RainCol;
    public bool Dark; public int Trail; public double Cell, Speed;
    // Chrome: 0 = обычное окно, 3 = classic (XP)
    public int Chrome;
    public byte CardAlpha;
    public bool Pixel { get; private set; }
    public bool Glass => Name is "Windows 7 Aero" or "Windows Vista" or "Glass" or "Prism Glass";
    public int ControlKind => Name=="Windows XP"?1:Name is "Windows 7 Aero" or "Windows Vista"?2:Name is "Alienwave" or "Alien Command"?3:Name is "Dark Fantasy" or "Vampire" or "Crimson Nocturne"?4:Name=="zxc 2003"?5:Name=="zxc"?6:0;
    public string Artwork => Name switch { "Alienwave" => "alien-studio.png", "Dark Fantasy" => "gothic-studio.png",
        "zxc 2003" => "zxc-2003-studio.png", _ => null };

    Theme(string n, bool dark, string bg, string card, string text, string sub, string acc, string acc2, string on, string track,
          string glyphs, int trail, double cell, double speed, string font = "Segoe UI", string rain = null,
          int chrome = 0, byte cardAlpha = 245) {
        Name = n; Dark = dark; Bg = bg; Card = card; Text = text; Sub = sub; Accent = acc; Accent2 = acc2; OnAccent = on; Track = track;
        Glyphs = glyphs; Trail = trail; Cell = cell; Speed = speed; Font = font; RainCol = rain ?? acc;
        Chrome = chrome; CardAlpha = cardAlpha;
    }

    public static readonly Theme[] All = {
        new("Network Studio", true,"#0C121C","#151F2D","#E6EDF6","#9BAEC5","#65B5F5","#7BD7C4","#081421","#243449","·",0,48,0),
        new("Pixel Terminal", true,"#0D1812","#18291F","#DBF2B8","#AFCA92","#BAE879","#F5C969","#172413","#2B4532","▪·",0,32,0) { Pixel = true },
        new("Pixel Arcade", true,"#14152B","#202442","#F7EAFF","#C4B7DE","#F5A349","#54DDE4","#281633","#363D64","▪·",0,32,0) { Pixel = true },
        new("Pixel Glacier", false,"#DCEAF8","#F2F7FF","#253152","#465983","#3460A7","#B44C80","#FFFFFF","#CCD8EF","▪·",0,32,0) { Pixel = true },
        new("Snow", false,"#EAF2F9","#FFFFFF","#24394D","#526B83","#518BB7","#86BAD4","#FFFFFF","#D6E5F0","❄❅·",2,32,0.65),
        new("Merry Christmas", true,"#101E1A","#1A3028","#FFF3DC","#BCC9B2","#CB4450","#E4BE70","#FFFFFF","#304B3D","❄✦·",2,34,0.7),
        new("Prism Glass", false,"#E8EBF3","#FFFFFF","#24364B","#5B708A","#729ACD","#BA8EC7","#FFFFFF","#DCE5F0","·",0,48,0,"Segoe UI",null,0,235),
        new("Alien Command", true,"#080E0C","#111F18","#E3FFE9","#91B9A0","#87E84D","#41CBA5","#071109","#263D2D","⌁⋄·",1,36,0.5,"Consolas"),
        new("Alienwave", true,"#0B1119","#151F29","#E4F6FF","#91A8BB","#61D5E8","#99A7D2","#071820","#273947","◇⌁·",1,36,0.6),
        new("Dark Fantasy", true,"#14110E","#241E18","#F2E6CD","#B5A484","#C3A066","#9A7046","#17110B","#3D3428","◇◆·",1,40,0.4,"Palatino Linotype"),
        new("zxc 2003", true,"#160B1B","#201328","#FAEAFB","#E3B7EA","#F77BFF","#A597FF","#251028","#4A245A","✦⋄▪",1,46,.7),
        new("zxc", true,"#201628","#302340","#FFF1FC","#E1C9EF","#FF9AD5","#A7CAFF","#26172D","#4A355B","·",4,36,11,"Bahnschrift","#DCC8FF"),
        new("Vampire", true,"#100C12","#21151F","#F5E7EF","#C19AAE","#C53B62","#D4B5C2","#FFF3F7","#3A2335","†·◇",1,38,0.5),
        new("Crimson Nocturne", true,"#130B0D","#281317","#FFE9E5","#C99F9A","#D8453D","#C4B0A3","#FFF8F3","#48272C","†·",1,40,0.5,"Cambria"),
        new("Windows 7 Aero", false,"#C4DDEB","#F5FAFF","#142C40","#426582","#337CB5","#70B9EB","#FFFFFF","#D6E5EF","·",0,48,0,"Segoe UI",null,0,240),
        new("Windows Vista", true,"#16232C","#253C49","#F0F8FF","#A8C2D1","#487D9E","#A7CEDD","#FFFFFF","#3D596A","·",0,48,0),
        new("Glass", true,"#111725","#1E283B","#F4F7FF","#BBCCE5","#A4BCFA","#91D9CD","#131B32","#34415B","·",0,48,0),
        // --- розовые / милые: сердца, цветы, мягкий дождь ---
        new("Bubblegum",       false, "#FFE9F3", "#FFFFFF", "#3B2A35", "#8B6B7D", "#FF8DC7", "#E0559A", "#FFFFFF", "#FFD6EA", "♡♥✿", 1, 32, 1.4),
        new("Sakura",          false, "#FFF1F5", "#FFFFFF", "#4A2F3B", "#9A7184", "#F4A6C0", "#D4678F", "#40202E", "#FCDCE8", "✿❀❁🌸", 1, 36, 0.9),
        new("Hot Pink",        false, "#FFBEDD", "#FFF3F9", "#44002C", "#8C2F63", "#FF2E93", "#C70069", "#FFFFFF", "#FFD9EC", "♥★✦", 2, 26, 2.4),
        new("Strawberry Milk", false, "#FFECEE", "#FFFFFF", "#4A2A30", "#9C6A73", "#FF9AA2", "#E2606F", "#40202E", "#FFD9DD", "♡🍓·", 1, 34, 1.2),
        new("Cotton Candy",    false, "#FFE3F6", "#FFFFFF", "#38284A", "#7C6A99", "#FF9BD2", "#6EC6F5", "#2E1E40", "#F2D4FF", "☁✦♡", 1, 30, 1.3),
        new("Midnight Pink",   true,  "#1B1020", "#2A1A33", "#F6E6F2", "#B79BB0", "#FF5FB1", "#FF8DC7", "#1B1020", "#46305A", "✦·♡★", 2, 28, 1.6),

        // --- matrix / code: длинный шлейф, быстро ---
        new("Cyberpunk",       true,  "#0B0B16", "#14142A", "#E8F6FF", "#7FA0B8", "#FCEE0A", "#FF2A6D", "#0B0B16", "#2B2B55", "0123456789ABCDEF¥₩", 12, 14, 14, "Consolas", "#FF2A6D"),
        new("Hacker", true, "#06100C", "#0E1C16", "#D6FDEA", "#91CAA9", "#67F4A6", "#B7F77F", "#082018", "#1A3629", "·", 0, 48, 0, "Consolas", null, 0, 225),
        new("Toxic",           true,  "#0A1208", "#121A10", "#D8FFB0", "#7AAA50", "#B8FF00", "#7CFC00", "#0A1208", "#1A2A14", "☢☣☢◆", 9, 15, 9, "Consolas", "#B8FF00"),

        // --- vapor / shapes ---
        new("Vaporwave",       true,  "#2A1B4D", "#3B2A66", "#F3E9FF", "#BBA6E8", "#FF71CE", "#01CDFE", "#2A1B4D", "#52408A", "▲◆▶◀●", 3, 28, 2.0),

        // XP — почти без дождя
        new("Windows XP",      false, "#ECE9D8", "#FFFFFF", "#000000", "#404040", "#245EDC", "#3C8CF4", "#FFFFFF", "#D4D0C8", "◆", 0, 48, 0.0, "Tahoma", "#245EDC", 3, 255),

        // --- спокойные / минимал ---
        new("Nord",            true,  "#2E3440", "#3B4252", "#ECEFF4", "#D8DEE9", "#88C0D0", "#81A1C1", "#2E3440", "#4C566A", "·∘◦", 1, 34, 0.7),
        new("Mono",            true,  "#121212", "#1E1E1E", "#EAEAEA", "#9A9A9A", "#FFFFFF", "#CFCFCF", "#121212", "#2A2A2A", "·—│", 1, 22, 0.5, "Consolas"),
        new("Dracula",         true,  "#282A36", "#44475A", "#F8F8F2", "#BD93F9", "#FF79C6", "#BD93F9", "#282A36", "#6272A4", "🦇★◆", 2, 24, 1.8),

        // --- стихии ---
        new("Ocean",           true,  "#0B1C2C", "#12283A", "#E6F4FF", "#7EB6D6", "#3DDCFF", "#1B9AAA", "#0B1C2C", "#1A3A50", "≈～≋≈", 4, 22, 2.2),
        new("Ember",           true,  "#1A0E0A", "#2A1810", "#FFE8D6", "#E8A87C", "#FF6B35", "#D94F04", "#1A0E0A", "#3D2418", "🔥✦*", 3, 26, 2.8),
        new("Ice",             false, "#EEF6FA", "#FFFFFF", "#1A3040", "#5A7A8A", "#4FC3F7", "#0288D1", "#FFFFFF", "#D4EAF4", "❄❅❆·", 2, 30, 0.8),
        new("Matcha",          false, "#F2F7EC", "#FFFFFF", "#2A3A28", "#6A8A68", "#7CB342", "#558B2F", "#FFFFFF", "#DCE8D4", "🍃✿·", 1, 34, 0.9),
        new("Lavender",        false, "#F3EEF9", "#FFFFFF", "#3A2A4A", "#8A7A9A", "#9B7EBD", "#7B5EA7", "#FFFFFF", "#E4D8F0", "✦✧♡", 1, 32, 1.1),
        new("Sunset",          false, "#FFF3E8", "#FFFFFF", "#3A2A20", "#9A6A50", "#FF8A5B", "#E85D04", "#FFFFFF", "#FFE0C8", "☀✦·", 2, 28, 1.6),

        // неон — быстрые искры
        new("Neon",            true,  "#0A0614", "#140A22", "#F8EFFF", "#B89AD4", "#FF2EA6", "#00F0FF", "#0A0614", "#2A1840", "◆◈✦▣", 5, 20, 3.5, "Segoe UI", "#00F0FF"),

        // --- новые красивые темы ---
        new("Aurora",          true,  "#0A1220", "#122033", "#E8F4FF", "#8AB4D0", "#5EF0C0", "#7B6CFF", "#0A1220", "#1A2A40", "✦✧·∘", 4, 24, 1.8),
        new("Rose Gold",       false, "#FFF5F0", "#FFFFFF", "#3A2420", "#9A6A60", "#E8A090", "#C07060", "#FFFFFF", "#F5E0D8", "♡✦·", 1, 32, 1.1),
        new("Midnight City",   true,  "#0C0C18", "#16162A", "#F0F0FF", "#9090C0", "#FF4D8D", "#4D9FFF", "#0C0C18", "#222240", "◆★·", 3, 22, 2.4),
        new("Forest",          true,  "#0C1610", "#14241A", "#E0F0E4", "#70A080", "#3DCC7A", "#A8E060", "#0C1610", "#1A3020", "☘✦·", 2, 28, 1.2),
        new("Candy Night",     true,  "#1A0A18", "#2A1428", "#FFE8F8", "#C090B0", "#FF6BCB", "#7B5CFF", "#1A0A18", "#3A2040", "♡✦☁", 3, 26, 2.0),
        new("Amber",           true,  "#18100A", "#281A10", "#FFF0E0", "#D0A070", "#FFB040", "#FF7040", "#18100A", "#3A2818", "✦·☀", 2, 26, 1.9),
        new("Glacier",         false, "#F0F6FA", "#FFFFFF", "#1A3040", "#5A8090", "#60D0E8", "#3080C0", "#FFFFFF", "#D8E8F0", "❄·∘", 2, 30, 0.7),
    };
}
