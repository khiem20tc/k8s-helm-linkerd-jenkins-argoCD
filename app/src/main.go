package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"user-service/proto"
	"user-service/src/handlers"
	"user-service/src/services"

	"github.com/gin-gonic/gin"
	grpcprom "github.com/grpc-ecosystem/go-grpc-middleware/providers/prometheus"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sirupsen/logrus"
	"github.com/spf13/viper"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func main() {
	// Initialize logger
	logger := logrus.New()
	logger.SetFormatter(&logrus.JSONFormatter{})

	// Initialize configuration
	initConfig(logger)

	level, err := logrus.ParseLevel(viper.GetString("log.level"))
	if err != nil {
		logger.Warnf("Invalid log level %q, falling back to info", viper.GetString("log.level"))
		level = logrus.InfoLevel
	}
	logger.SetLevel(level)

	// Initialize metrics
	registry := prometheus.NewRegistry()
	grpcMetrics := grpcprom.NewServerMetrics()
	registry.MustRegister(
		grpcMetrics,
		prometheus.NewGoCollector(),
		prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}),
	)

	// Initialize services
	userService := services.NewUserService(logger)

	// Start gRPC server
	grpcServer, healthServer := startGRPCServer(userService, grpcMetrics, logger)

	// Start HTTP server for health checks and metrics
	httpServer := startHTTPServer(registry, logger)

	// Wait for interrupt signal to gracefully shutdown the servers
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	logger.Info("Shutting down servers...")

	// Stop receiving new traffic before draining in-flight requests
	healthServer.Shutdown()

	// Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	grpcServer.GracefulStop()

	if err := httpServer.Shutdown(ctx); err != nil {
		logger.Errorf("HTTP server forced to shutdown: %v", err)
	}

	logger.Info("Servers exited")
}

func initConfig(logger *logrus.Logger) {
	viper.SetDefault("grpc.port", "50051")
	viper.SetDefault("http.port", "8080")
	viper.SetDefault("log.level", "info")

	// Environment variables override the config file, e.g. GRPC_PORT, HTTP_PORT, LOG_LEVEL
	viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	viper.AutomaticEnv()

	if path := os.Getenv("CONFIG_PATH"); path != "" {
		viper.SetConfigFile(path)
	} else {
		viper.SetConfigName("config")
		viper.SetConfigType("yaml")
		viper.AddConfigPath("./configs")
		viper.AddConfigPath(".")
	}

	if err := viper.ReadInConfig(); err != nil {
		logger.Warnf("Could not read config file, using defaults: %v", err)
	}
}

func startGRPCServer(userService *services.UserService, metrics *grpcprom.ServerMetrics, logger *logrus.Logger) (*grpc.Server, *health.Server) {
	port := viper.GetString("grpc.port")
	lis, err := net.Listen("tcp", ":"+port)
	if err != nil {
		logger.Fatalf("Failed to listen on port %s: %v", port, err)
	}

	grpcServer := grpc.NewServer(
		grpc.ChainUnaryInterceptor(metrics.UnaryServerInterceptor()),
		grpc.ChainStreamInterceptor(metrics.StreamServerInterceptor()),
	)

	// Register services
	proto.RegisterUserServiceServer(grpcServer, handlers.NewUserHandler(userService, logger))

	// Standard gRPC health checking protocol (used by grpc_health_probe, Linkerd, etc.)
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus("user.UserService", healthpb.HealthCheckResponse_SERVING)

	// Enable reflection for debugging
	reflection.Register(grpcServer)

	metrics.InitializeMetrics(grpcServer)

	logger.Infof("gRPC server listening on port %s", port)

	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fatalf("Failed to serve gRPC: %v", err)
		}
	}()

	return grpcServer, healthServer
}

func startHTTPServer(registry *prometheus.Registry, logger *logrus.Logger) *http.Server {
	port := viper.GetString("http.port")

	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())

	// Health check endpoint
	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"status":    "healthy",
			"timestamp": time.Now().UTC(),
			"service":   "user-service",
		})
	})

	// Readiness probe
	router.GET("/ready", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"status": "ready",
		})
	})

	// Prometheus metrics endpoint
	router.GET("/metrics", gin.WrapH(promhttp.HandlerFor(registry, promhttp.HandlerOpts{})))

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	logger.Infof("HTTP server listening on port %s", port)

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Fatalf("Failed to start HTTP server: %v", err)
		}
	}()

	return srv
}
