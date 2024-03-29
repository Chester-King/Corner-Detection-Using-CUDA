#include <stdio.h>
#include <ctime>
#include <string>
#include <iostream>
#include <iomanip>
using namespace std;

#include "Matrix.h" //Matrix class
#include "utils.h" //Utils used in both Gauss and Sobel
#include "Gauss.h" //Serial Gauss
#include "Sobel.h" //Serial Sobel
#include "GaussFilter.cuh" //Parallel Gauss
#include "SobelFilter.cuh" //Parallel Sobel
#define DYNAMIC_GAUSS //Comment if you want to use static parameters in tiled convolution
#define DYNAMIC_SOBEL //Comment if you want to use static parameters in tiled convolution
float parallelCornerDetector(Matrix grayImage, Matrix gaussianKernel, string pathName, int numThreads);
float serialCornerDetector(Matrix grayImage, Matrix gaussianKernel, string pathName);

int main(int argc, char* argv[]) {
	//if (argc == 1) {
		//cout << "ERROR: Enter the name or path of an image file.\n" << endl;
		//return 0;
	//}

	string imagePathName("C:\\Users\\Shivam Dixit\\Documents\\Visual Studio 2015\\Projects\\CornerDetector\\CornerDetector\\skele.ppm");

	//Default Values
	int gaussKernelSize = 7;
	int numThreads = 32; //Threads per block -- 32x32 or 16x16 or 8x8
	double sigma = 1.5;

	for (int i = 2; i < argc; ++i) {
		string key = getKey(string(argv[i]));
		string val = getValue(string(argv[i]));
		if (key == "gaussMask") {
			gaussKernelSize = toInt(val);
		}
		else if (key == "sigma") {
			sigma = toDouble(val);
		}
		else if (key == "tpb") {
			numThreads = toInt(val);
		}
	}

	if (gaussKernelSize % 2 == 0) {
		cout << "Mask has to be odd." << endl;
		return 0;
	}

	//cout << endl;
	//cout << " --- Image Corner Detector --- " << endl;
	//cout << endl <<endl;

	//////////////Read Image///////////////
	cout << endl;
	PPMImage *image = readPPM(imagePathName.c_str());
	string outputFileName = getFileName(imagePathName, false);
	cout << getFileName(imagePathName) << " -------------" << endl;
	//cout << imagePathName << " -------------" << endl;
	cout << endl;

	//////////////Pre-Processing///////////////////
	Matrix grayImage = rgb2gray(image);
	Matrix gaussianKernel = createGaussianKernel(gaussKernelSize, sigma);

	//////////////Serial Processing/////////////////
	double serialTime = serialCornerDetector(grayImage, gaussianKernel, outputFileName);

	//////////////Parallel Processing///////////////
	double parallelTime = parallelCornerDetector(grayImage, gaussianKernel, outputFileName, numThreads);

	cout << "Speedup: " << serialTime / parallelTime << endl;

	//Free memory
	freeImage(image);

	return 0;
}


/*
Parallel Corner Detection using CUDA
*/
float parallelCornerDetector(Matrix grayImage, Matrix gaussianKernel, string pathName, int numThreads) {

	int imageWidth = grayImage.getCols(), imageHeight = grayImage.getRows();
	int imageSize = imageWidth * imageHeight;
	int kernelSize = gaussianKernel.getRows();
	float gaussTime = 0.0, sobelTime = 0.0;
	cudaEvent_t start, stop;
	cudaEventCreate(&start);	cudaEventCreate(&stop);
	cudaError_t err;

	//Arrays of CPU
	float* result = allocateArray(imageSize);
	float* grayImageArray = grayImage.toArray();
	float* gaussKernelArray = gaussianKernel.toArray();
	float* xGradient = getGradientX(), *yGradient = getGradientY(); //Used in Sobel

																	//Arrays used in GPU
	float* kernelDevice; //Used in Gauss
	float* xGradDevice, *yGradDevice; //Used in Sobel
	float* imageDevice, *resultDevice; //Used in both Gauss and Sobel

									   //Allocate Device Memory
	cudaMalloc((void**)&imageDevice, imageSize * sizeof(float));
	cudaMalloc((void**)&resultDevice, imageSize * sizeof(float));
	cudaMalloc((void**)&kernelDevice, kernelSize * kernelSize * sizeof(float));
	cudaMalloc((void**)&xGradDevice, SOBEL_MASK_SIZE * SOBEL_MASK_SIZE * sizeof(float));
	cudaMalloc((void**)&yGradDevice, SOBEL_MASK_SIZE * SOBEL_MASK_SIZE * sizeof(float));

	//Copy values from CPU to GPU
	cudaMemcpy(imageDevice, grayImageArray, imageSize * sizeof(float), cudaMemcpyHostToDevice);
	cudaMemcpy(kernelDevice, gaussKernelArray, kernelSize * kernelSize * sizeof(float), cudaMemcpyHostToDevice);

	cudaMemcpy(xGradDevice, xGradient, SOBEL_MASK_SIZE * SOBEL_MASK_SIZE * sizeof(float), cudaMemcpyHostToDevice);
	cudaMemcpy(yGradDevice, yGradient, SOBEL_MASK_SIZE * SOBEL_MASK_SIZE * sizeof(float), cudaMemcpyHostToDevice);

	///////////////////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////Gaussian Blur to Remove Noise////////////////////////////////
	//////Tiled Convolution
#ifdef DYNAMIC_GAUSS
	int tileWidth = numThreads - kernelSize + 1;
	int blockWidth = tileWidth + kernelSize - 1;
	dim3 dimGaussBlock(blockWidth, blockWidth);
	dim3 dimGaussGrid((imageWidth - 1) / tileWidth + 1, (imageHeight - 1) / tileWidth + 1);
#else
	dim3 dimGaussBlock(GAUSS_BLOCK_WIDTH, GAUSS_BLOCK_WIDTH);
	dim3 dimGaussGrid((imageWidth - 1) / GAUSS_TILE_WIDTH + 1, (imageHeight - 1) / GAUSS_TILE_WIDTH + 1);
#endif
	//Start recording GPU time
	cudaEventRecord(start, 0);
#ifdef DYNAMIC_GAUSS
	DynamicTiledConvolution << < dimGaussGrid, dimGaussBlock, blockWidth * blockWidth * sizeof(float) >> > (imageDevice, resultDevice, imageWidth, imageHeight, kernelDevice, kernelSize, tileWidth, blockWidth);
#else	
	tiledConvolution << < dimGaussGrid, dimGaussBlock, 1 >> > (imageDevice, resultDevice, imageWidth, imageHeight, kernelDevice, kernelSize);
#endif	
	err = cudaGetLastError();
	if (err != cudaSuccess)	printf("Gauss Error: %s\n", cudaGetErrorString(err));
	//GPU time recording finished
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);

	//Copy GPU Time
	cudaEventElapsedTime(&gaussTime, start, stop);
	gaussTime *= 0.001;//Milliseconds to Seconds
					   //////End Tiled Convolution
					   ///////////////////////////////////////////////////////////////////////////////////////////////

	cudaDeviceSynchronize();

	///////////////////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////Sobel Filter to Detect Corners////////////////////////////////	

	//Tiled Sobel Filter
#ifdef DYNAMIC_SOBEL
	int sobelTileWidth = numThreads - SOBEL_MASK_SIZE + 1;
	int sobelBlockWidth = sobelTileWidth + SOBEL_MASK_SIZE - 1;
	dim3 dimBlockSobel(sobelBlockWidth, sobelBlockWidth);
	dim3 dimGridSobel((imageWidth - 1) / sobelTileWidth + 1, (imageHeight - 1) / sobelTileWidth + 1);
#else
	dim3 dimBlockSobel(SOBEL_BLOCK_WIDTH, SOBEL_BLOCK_WIDTH);
	dim3 dimGridSobel((imageWidth - 1) / SOBEL_TILE_WIDTH + 1, (imageHeight - 1) / SOBEL_TILE_WIDTH + 1);
#endif
	//Copy result obtained from Gauss as new Image Data
	cudaMemcpy(imageDevice, resultDevice, imageSize * sizeof(float), cudaMemcpyDeviceToDevice);

	//Start recording GPU time
	cudaEventRecord(start, 0);
#ifdef DYNAMIC_SOBEL
	DynamicSobelConvolution << < dimGaussGrid, dimGaussBlock, blockWidth * blockWidth * sizeof(float) >> > (imageDevice, resultDevice, imageWidth, imageHeight, xGradDevice, yGradDevice, sobelTileWidth, sobelBlockWidth);
#else	
	tiledSobelConvolution << < dimGridSobel, dimBlockSobel >> > (imageDevice, resultDevice, imageWidth, imageHeight, xGradDevice, yGradDevice);
#endif	
	err = cudaGetLastError();
	if (err != cudaSuccess)	printf("Sobel Error: %s\n", cudaGetErrorString(err));

	//GPU time recording finished
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);

	//Copy GPU Time
	cudaEventElapsedTime(&sobelTime, start, stop);
	sobelTime *= 0.001; //Milliseconds to Seconds
						////////////////////////////////////////////////////////////////////////////////////////////////////////////

						//Copy Result from GPU to CPU
	cudaMemcpy(result, resultDevice, imageSize * sizeof(float), cudaMemcpyDeviceToHost);

	///////////////Save Image Result/////////////////
	PPMImage* imageResult = createImage(imageHeight, imageWidth);
	Matrix dataResult = arrayToMatrix(result, imageHeight, imageWidth);
	Matrix normalized = normalize(dataResult, 0, 255); //Normalize values
	matrixToImage(normalized, imageResult);
#ifdef _WIN32
	pathName = pathName + "_gpu.ppm";
#else
	pathName = "../output/" + pathName + "_gpu.ppm";
#endif
	writePPM(pathName.c_str(), imageResult);
	freeImage(imageResult);
	/////////////////////////////////////////////////

	cout << "GPU Gauss Time: " << setprecision(3) << fixed << gaussTime << "s." << endl;
	cout << "GPU Sobel Time: " << setprecision(3) << fixed << sobelTime << "s." << endl;
	cout << "GPU Time: " << setprecision(3) << fixed << gaussTime + sobelTime << "s." << endl;

	////////////////Free Memory used in GPU and CPU//////////////////
	cudaFree(xGradDevice);	cudaFree(yGradDevice); cudaFree(imageDevice);
	cudaFree(resultDevice); cudaFree(kernelDevice);
	freeArray(xGradient);	freeArray(yGradient);  freeArray(result);
	freeArray(grayImageArray); freeArray(gaussKernelArray);
	/////////////////////////////////////////////////////////////////
	return gaussTime + sobelTime;
}

/*
Serial Corner Detection
*/
float serialCornerDetector(Matrix grayImage, Matrix gaussianKernel, string pathName) {
	clock_t startTime, endTime, clockTicksTaken;
	///////////////Gaussian Blur to Remove Noise//////////////
	float* grayImageArray = grayImage.toArray(), *kernelArray = gaussianKernel.toArray();
	startTime = clock();
	Matrix noiseRemoval = GaussianBlur(grayImageArray, kernelArray, grayImage.getRows(),
		grayImage.getCols(), gaussianKernel.getRows());
	//Matrix noiseRemoval = GaussianBlur(grayImage, gaussianKernel);
	endTime = clock();
	clockTicksTaken = endTime - startTime;
	double gaussTime = clockTicksTaken / (double)CLOCKS_PER_SEC; //gaussTime *= 1000.0;
	freeArray(grayImageArray);
	freeArray(kernelArray);
	///////////////////////////////////////////////////////////

	///////////////Sobel Filter to Detect Corners//////////////
	float* noiseRemovalArray = noiseRemoval.toArray();
	startTime = clock();
	Matrix sobel = sobelFilter(noiseRemovalArray, noiseRemoval.getRows(), noiseRemoval.getCols());
	//Matrix sobel = sobelFilter(noiseRemoval);
	endTime = clock();
	clockTicksTaken = endTime - startTime;
	double sobelTime = clockTicksTaken / (double)CLOCKS_PER_SEC; //sobelTime *= 1000.0;
	freeArray(noiseRemovalArray);
	///////////////////////////////////////////////////////////

	///////////////Save Image Result/////////////////
	PPMImage* result = createImage(sobel.getRows(), sobel.getCols());
	Matrix normalized = normalize(sobel, 0, 255);
	matrixToImage(normalized, result);
#ifdef _WIN32
	pathName = pathName + "_cpu.ppm";
#else
	pathName = "../output/" + pathName + "_cpu.ppm";
#endif
	writePPM(pathName.c_str(), result);
	freeImage(result);
	/////////////////////////////////////////////////

	cout << "CPU Gauss Time: " << gaussTime << "s." << endl;
	cout << "CPU Sobel Time: " << sobelTime << "s." << endl;
	cout << "CPU Time: " << gaussTime + sobelTime << "s." << endl;

	return gaussTime + sobelTime;
}