mod app;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Goal Studio")
            .with_inner_size([1440.0, 920.0])
            .with_min_inner_size([920.0, 640.0]),
        ..Default::default()
    };

    eframe::run_native(
        "Goal Studio",
        options,
        Box::new(|cc| Ok(Box::new(app::GoalStudioApp::new(cc)))),
    )
}
