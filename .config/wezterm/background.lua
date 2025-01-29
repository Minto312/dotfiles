local env = require("env")

return {
    {source = {File = env.background_image}}, {
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
