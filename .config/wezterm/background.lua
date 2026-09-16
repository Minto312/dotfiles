local env = require("env")

return {
    {
        source = {File = env.background_image},
        -- 壁紙をそのまま敷くと herdr のサイドバーが読めなくなる。
        -- herdr の tokyo-night は sidebar_bg = Color::Reset なので、
        -- サイドバーの背景は「外側ターミナルの背景」= この壁紙そのものになる。
        -- この壁紙は左端 (= サイドバーが乗る帯) が一番明るく、輝度 136〜255 ある。
        -- brightness で画像だけを落とし、下地の明暗差を潰す。1.0 = 元の明るさ。
        hsb = {hue = 1.0, saturation = 1.0, brightness = 0.15}
    }, {
        source = {
            Gradient = {
                colors = {"#16264b", "#1d3467"},
                orientation = "Vertical" -- グラデーションの向き
            }
        },
        opacity = 0.8, -- 透明度
        width = "100%", -- 幅
        height = "100%" -- 高さ
    }
}
