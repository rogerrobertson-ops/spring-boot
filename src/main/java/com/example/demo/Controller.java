package com.example.demo;

import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api")
public class Controller {

    @GetMapping("/health")
    public String health() {
        return "UP";
    }

    @GetMapping("/inventory")
    public String inventory() {
        return "Inventory service running";
    }
}